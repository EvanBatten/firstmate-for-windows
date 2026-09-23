import { spawn } from "node:child_process";
import net from "node:net";
import { existsSync } from "node:fs";

const READY_BANNER = "bypass permissions on";
const TRUST = "Yes, I trust this folder";
const PROMPT_RE = /(^|\n)\$ *$/m;

function herdrBin(explicit) {
  if (explicit) return explicit;
  if (process.env.FM_CONTROL_HERDR) return process.env.FM_CONTROL_HERDR;
  return process.platform === "win32" ? "herdr.exe" : "herdr";
}

function winPath(p) {
  if (process.platform !== "win32") return p;
  if (/^[A-Za-z]:[\\/]/.test(p)) return p;
  return p.replace(/\//g, "\\");
}

/**
 * Socket-first herdr client.
 * One long-lived AF_UNIX connection after at most two CLI spawns
 * (status, and server start if the named session is down).
 * Feature waits never call this.
 */
export class HerdrClient {
  constructor(opts = {}) {
    this.bin = herdrBin(opts.bin);
    this.sessionName = opts.sessionName || `fm-ctl-${process.pid}`;
    this.socketPath = opts.socketPath || process.env.FM_CONTROL_SOCKET || null;
    this.sock = null;
    this.buf = "";
    this.nextId = 1;
    this.pending = new Map();
    this.herdrCalls = 0;
    this.spawns = 0;
    this.startedServer = false;
    this.serverChild = null;
    this.dead = false;
    this.lastText = "";
    this.lastStatus = "unknown";
  }

  async spawnHerdr(args, { timeoutMs = 30_000, parseJson = true } = {}) {
    this.spawns += 1;
    this.herdrCalls += 1;
    const argv = ["--session", this.sessionName, ...args];
    return new Promise((resolve, reject) => {
      const child = spawn(this.bin, argv, {
        shell: false,
        windowsHide: true,
        env: {
          ...process.env,
          MSYS2_ARG_CONV_EXCL: "*",
        },
      });
      let stdout = "";
      let stderr = "";
      const timer = setTimeout(() => {
        child.kill();
        reject(new Error(`herdr timed out: ${args.join(" ")}`));
      }, timeoutMs);
      child.stdout.on("data", (d) => {
        stdout += d.toString("utf8");
      });
      child.stderr.on("data", (d) => {
        stderr += d.toString("utf8");
      });
      child.on("error", (err) => {
        clearTimeout(timer);
        reject(err);
      });
      child.on("close", (code) => {
        clearTimeout(timer);
        if (parseJson) {
          try {
            resolve({ code, stdout, stderr, json: JSON.parse(stdout) });
            return;
          } catch {
            reject(new Error(`herdr not JSON (${code}): ${stderr || stdout}`.slice(0, 400)));
            return;
          }
        }
        resolve({ code, stdout, stderr, json: null });
      });
    });
  }

  async connect() {
    if (this.sock) return;
    if (!this.socketPath) {
      const status = await this.spawnHerdr(["status", "--json"]);
      const server = status.json?.server || {};
      this.socketPath = server.socket;
      if (!server.running) {
        await this.startServer();
      }
    }
    if (!this.socketPath) {
      throw new Error("herdr status did not name a socket");
    }
    await this.openSocket();
  }

  async startServer() {
    this.spawns += 1;
    this.herdrCalls += 1;
    this.startedServer = true;
    this.serverChild = spawn(this.bin, ["--session", this.sessionName, "server"], {
      shell: false,
      windowsHide: true,
      stdio: "ignore",
      env: { ...process.env, MSYS2_ARG_CONV_EXCL: "*" },
    });
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline) {
      try {
        const status = await this.spawnHerdr(["status", "--json"]);
        if (status.json?.server?.running && status.json.server.socket) {
          this.socketPath = status.json.server.socket;
          return;
        }
      } catch {
        /* still coming up */
      }
      await new Promise((r) => setTimeout(r, 150));
    }
    throw new Error("herdr server did not become ready");
  }

  openSocket() {
    return new Promise((resolve, reject) => {
      const sock = net.connect({ path: this.socketPath });
      const onErr = (err) => reject(err);
      sock.once("error", onErr);
      sock.once("connect", () => {
        sock.off("error", onErr);
        this.sock = sock;
        sock.setEncoding("utf8");
        sock.on("data", (chunk) => this.onData(chunk));
        sock.on("error", () => {
          this.dead = true;
        });
        sock.on("close", () => {
          this.sock = null;
        });
        resolve();
      });
    });
  }

  onData(chunk) {
    this.buf += chunk;
    let nl;
    while ((nl = this.buf.indexOf("\n")) >= 0) {
      const line = this.buf.slice(0, nl);
      this.buf = this.buf.slice(nl + 1);
      if (!line.trim()) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.error.message || "herdr rpc error"));
        else resolve(msg.result);
      }
    }
  }

  async rpc(method, params = {}, timeoutMs = 30_000) {
    if (!this.sock) await this.connect();
    this.herdrCalls += 1;
    const id = `fm-${this.nextId++}`;
    const payload = JSON.stringify({ id, method, params }) + "\n";
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`rpc timeout: ${method}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (v) => {
          clearTimeout(timer);
          resolve(v);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
      this.sock.write(payload);
    });
  }

  async workspaceCreate({ cwd, label, env }) {
    const result = await this.rpc("workspace.create", {
      cwd: winPath(cwd),
      label,
      focus: false,
      env: env || {},
    });
    const workspaceId = result?.workspace?.workspace_id;
    const paneId = result?.root_pane?.pane_id;
    const tabId = result?.tab?.tab_id;
    if (!workspaceId || !paneId) {
      throw new Error("workspace.create returned no pane");
    }
    return { workspaceId, paneId, tabId, raw: result };
  }

  async workspaceClose(workspaceId) {
    try {
      await this.rpc("workspace.close", { workspace_id: workspaceId });
    } catch {
      /* already gone */
    }
  }

  async workspaceFocus(workspaceId) {
    await this.rpc("workspace.focus", { workspace_id: workspaceId });
  }

  async paneRun(paneId, text) {
    await this.rpc("pane.send_input", { pane_id: paneId, text, keys: ["enter"] });
  }

  async paneSendKeys(paneId, keys) {
    await this.rpc("pane.send_keys", { pane_id: paneId, keys: Array.isArray(keys) ? keys : [keys] });
  }

  async paneRead(paneId, lines = 80) {
    const result = await this.rpc("pane.read", {
      pane_id: paneId,
      source: "recent_unwrapped",
      lines,
      strip_ansi: true,
    });
    const text =
      typeof result === "string"
        ? result
        : result?.read?.text || result?.text || result?.output || result?.content || "";
    this.lastText = text;
    return text;
  }

  async paneGet(paneId) {
    const result = await this.rpc("pane.get", { pane_id: paneId });
    const status = result?.pane?.agent_status || result?.agent_status || "unknown";
    this.lastStatus = status;
    return result;
  }

  async paneWaitOutput(paneId, { substring, regex, timeoutMs }) {
    const match = regex
      ? { type: "regex", value: regex }
      : { type: "substring", value: substring };
    return this.rpc(
      "pane.wait_for_output",
      {
        pane_id: paneId,
        source: "recent_unwrapped",
        match,
        strip_ansi: true,
        timeout_ms: timeoutMs,
      },
      timeoutMs + 2000,
    );
  }

  atShellPrompt(text = this.lastText) {
    return PROMPT_RE.test(String(text || "").replace(/\r/g, ""));
  }

  isDead() {
    return this.dead || this.atShellPrompt();
  }

  async refreshDead(paneId) {
    try {
      await this.paneGet(paneId);
      const text = await this.paneRead(paneId, 8);
      if (this.atShellPrompt(text)) this.dead = true;
    } catch {
      this.dead = true;
    }
    return this.dead;
  }

  async close({ stopSession = false } = {}) {
    if (this.sock) {
      try {
        this.sock.end();
      } catch {
        /* ignore */
      }
      this.sock = null;
    }
    if (stopSession && this.startedServer) {
      try {
        await this.spawnHerdr(["session", "stop"], { parseJson: true, timeoutMs: 10_000 });
      } catch {
        if (this.serverChild) {
          try {
            this.serverChild.kill();
          } catch {
            /* ignore */
          }
        }
      }
    }
  }
}

export function herdrExists(bin) {
  if (!bin) return true;
  if (bin.includes("/") || bin.includes("\\")) return existsSync(bin);
  return true;
}

export { READY_BANNER, TRUST, herdrBin, winPath };
