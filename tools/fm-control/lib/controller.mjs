import { EventEmitter } from "node:events";
import { spawn } from "node:child_process";
import { createConnection } from "node:net";
import { once } from "node:events";

class JsonLines extends EventEmitter {
  constructor(readable, writable) {
    super();
    this.readable = readable;
    this.writable = writable;
    this.buffer = "";
    this.sequence = 0;
    this.pending = new Map();
    readable.setEncoding("utf8");
    readable.on("data", (chunk) => this.consume(chunk));
    readable.on("error", (error) => this.rejectAll(error));
    readable.on("close", () => this.rejectAll(new Error("Herdr connection closed")));
  }

  consume(chunk) {
    this.buffer += chunk;
    while (this.buffer.includes("\n")) {
      const split = this.buffer.indexOf("\n");
      const line = this.buffer.slice(0, split);
      this.buffer = this.buffer.slice(split + 1);
      if (!line.trim()) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        continue;
      }
      if (message.event) {
        this.emit("event", message);
        continue;
      }
      const pending = this.pending.get(String(message.id));
      if (!pending) continue;
      this.pending.delete(String(message.id));
      clearTimeout(pending.timer);
      if (message.error) {
        pending.reject(new Error(message.error.message || "Herdr request failed"));
      } else {
        pending.resolve(message.result);
      }
    }
  }

  request(method, params = {}, timeoutMs = 30000) {
    const id = `fm-control-${process.pid}-${++this.sequence}`;
    return new Promise((resolveRequest, rejectRequest) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rejectRequest(new Error(`Herdr ${method} deadline exceeded`));
      }, timeoutMs);
      this.pending.set(id, { resolve: resolveRequest, reject: rejectRequest, timer });
      this.writable.write(`${JSON.stringify({ id, method, params })}\n`, (error) => {
        if (!error) return;
        clearTimeout(timer);
        this.pending.delete(id);
        rejectRequest(error);
      });
    });
  }

  rejectAll(error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }

  close() {
    this.rejectAll(new Error("Herdr connection closed"));
    this.writable.end?.();
    this.readable.destroy?.();
  }
}

function executableAndArgs(path) {
  if (path.endsWith(".mjs") || path.endsWith(".js")) {
    return { executable: process.execPath, args: [path] };
  }
  return { executable: path, args: [] };
}

function spawnCaptured(executable, args, options, metrics, herdr = true) {
  metrics.spawns += 1;
  if (herdr) metrics.herdrCalls += 1;
  const child = spawn(executable, args, {
    shell: false,
    windowsHide: true,
    ...options,
  });
  return child;
}

async function capture(executable, args, env, metrics) {
  const child = spawnCaptured(
    executable,
    args,
    { env, stdio: ["ignore", "pipe", "pipe"] },
    metrics,
  );
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const [code] = await once(child, "close");
  if (code !== 0) throw new Error(`Herdr status failed with exit ${code}`);
  return stdout;
}

async function connectSocket(path, deadlineMs) {
  let lastError = null;
  while (Date.now() < deadlineMs) {
    const socket = createConnection(path);
    try {
      await Promise.race([
        once(socket, "connect"),
        once(socket, "error").then(([error]) => Promise.reject(error)),
      ]);
      return socket;
    } catch (error) {
      lastError = error;
      socket.destroy();
      await new Promise((resolveWait) => setTimeout(resolveWait, 20));
    }
  }
  throw new Error(`could not connect to Herdr server: ${lastError?.message || "deadline"}`);
}

export class HerdrController extends EventEmitter {
  constructor({ env, home, metrics }) {
    super();
    this.env = env;
    this.home = home;
    this.metrics = metrics;
    this.control = null;
    this.stream = null;
    this.server = null;
    this.fake = null;
    this.socketPath = null;
  }

  async connect() {
    const fakePath = this.env.FM_CONTROL_FAKE_HERDR;
    if (fakePath) {
      const command = executableAndArgs(fakePath);
      this.fake = spawnCaptured(
        command.executable,
        command.args,
        {
          env: { ...this.env, FM_CONTROL_HOME: this.home },
          stdio: ["pipe", "pipe", "inherit"],
        },
        this.metrics,
      );
      this.control = new JsonLines(this.fake.stdout, this.fake.stdin);
      this.control.on("event", (event) => this.emit("event", event));
      return;
    }

    const herdr = this.env.FM_CONTROL_HERDR || (process.platform === "win32" ? "herdr.exe" : "herdr");
    const session = `fm-control-${process.pid}-${Date.now().toString(36)}`;
    const statusText = await capture(
      herdr,
      ["--session", session, "status", "--json"],
      this.env,
      this.metrics,
    );
    let status;
    try {
      status = JSON.parse(statusText);
    } catch {
      throw new Error("Herdr status returned invalid JSON");
    }
    const socketPath = status?.server?.socket;
    if (!socketPath) throw new Error("Herdr status reported no socket path");
    this.socketPath = socketPath;

    this.server = spawnCaptured(
      herdr,
      ["--session", session, "server"],
      { env: this.env, stdio: "ignore", detached: false },
      this.metrics,
    );
    this.server.on("error", (error) => this.emit("failure", error));
    const deadline = Date.now() + 30000;
    const streamSocket = await connectSocket(socketPath, deadline);
    this.stream = new JsonLines(streamSocket, streamSocket);
    this.stream.on("event", (event) => this.emit("event", event));
  }

  async request(method, params = {}, timeoutMs = 30000) {
    if (this.control) return this.control.request(method, params, timeoutMs);
    const socket = await connectSocket(this.socketPath, Date.now() + timeoutMs);
    const peer = new JsonLines(socket, socket);
    try {
      return await peer.request(method, params, timeoutMs);
    } finally {
      peer.close();
    }
  }

  async subscribe(paneId) {
    const peer = this.stream || this.control;
    const subscriptions = [
      { type: "pane.agent_status_changed", pane_id: paneId },
      {
        type: "pane.output_matched",
        pane_id: paneId,
        source: "recent_unwrapped",
        match: { type: "substring", value: "bypass permissions on" },
        strip_ansi: true,
      },
      {
        type: "pane.output_matched",
        pane_id: paneId,
        source: "recent_unwrapped",
        match: { type: "substring", value: "Background work is running" },
        strip_ansi: true,
      },
      {
        type: "pane.output_matched",
        pane_id: paneId,
        source: "recent_unwrapped",
        match: { type: "regex", value: "[$#>]\\s*$" },
        strip_ansi: true,
      },
    ];
    const result = await peer.request("events.subscribe", { subscriptions });
    if (result?.type !== "subscription_started") {
      throw new Error("Herdr did not start the event subscription");
    }
  }

  sendInput(paneId, text, keys = ["enter"]) {
    return this.request("pane.send_input", { pane_id: paneId, text, keys });
  }

  sendKeys(paneId, keys) {
    return this.request("pane.send_keys", { pane_id: paneId, keys });
  }

  async close() {
    this.stream?.close();
    this.control?.close();
    if (this.fake && !this.fake.killed) this.fake.kill();
    if (this.server && !this.server.killed) this.server.kill();
  }
}
