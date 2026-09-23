import { createServer } from "node:net";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  appendFileSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";

function journalLine(journal, obj) {
  if (!journal) return;
  appendFileSync(journal, JSON.stringify(obj) + "\n");
}

function writeLock(home, text) {
  mkdirSync(join(home, "state"), { recursive: true });
  writeFileSync(join(home, "state", ".lock"), text);
}

function registerGreeter(home, origin) {
  mkdirSync(join(home, "data"), { recursive: true });
  mkdirSync(join(home, "projects"), { recursive: true });
  writeFileSync(
    join(home, "data", "projects.md"),
    "- greeter [local-only] - throwaway verification project\n",
  );
  const dest = join(home, "projects", "greeter");
  if (!existsSync(join(dest, ".git"))) {
    execFileSync("git", ["clone", "-q", origin, dest]);
  }
}

function dispatch(home, kind = "ship") {
  mkdirSync(join(home, "state"), { recursive: true });
  writeFileSync(join(home, "state", "t1.meta"), `kind=${kind}\nherdr_pane_id=w1:p2\n`);
  writeFileSync(join(home, "state", "t1.status"), "working: dispatched\n");
}

function writeReport(home) {
  mkdirSync(join(home, "data", "t1"), { recursive: true });
  writeFileSync(
    join(home, "data", "t1", "report.md"),
    "# greeter\n\nRecommend greet.sh subcommands hello, bye, version.\n",
  );
}

function promote(home) {
  writeFileSync(join(home, "state", "t1.meta"), "kind=ship\nherdr_pane_id=w1:p2\n");
  mkdirSync(join(home, "data", "t1"), { recursive: true });
  writeFileSync(join(home, "data", "t1", "ship-instructions.md"), "ship greet.sh\n");
}

function land(home) {
  const repo = join(home, "projects", "greeter");
  if (!existsSync(join(repo, ".git"))) return;
  try {
    execFileSync("git", ["config", "user.email", "verify@example.invalid"], { cwd: repo });
    execFileSync("git", ["config", "user.name", "verification"], { cwd: repo });
    writeFileSync(join(repo, "greet.sh"), "#!/bin/sh\necho hello\n");
    const readme = existsSync(join(repo, "README.md"))
      ? readFileSync(join(repo, "README.md"), "utf8")
      : "";
    writeFileSync(join(repo, "README.md"), `${readme}\n## version\n`);
    execFileSync("git", ["add", "-A"], { cwd: repo });
    execFileSync("git", ["commit", "-qm", "add greet.sh"], { cwd: repo });
  } catch {
    /* already landed */
  }
}

function clean(home) {
  try {
    execFileSync("rm", ["-f", join(home, "state", "t1.meta"), join(home, "state", "t1.status")]);
  } catch {
    /* ignore */
  }
}

export function applyCaptainText(home, text, origin) {
  if (!home) return;
  if (/claude/.test(text) && /dangerously-skip-permissions/.test(text)) {
    const n = existsSync(join(home, "state", ".lock")) ? "lock-2" : "lock-1";
    writeLock(home, n);
    return;
  }
  if (text === "/exit") return;
  if (/add my project|local-only project/.test(text)) {
    registerGreeter(home, origin);
    dispatch(home, /investigate|written report|scout/i.test(text) ? "scout" : "ship");
    if (/investigate|written report|scout/i.test(text)) writeReport(home);
    return;
  }
  if (/I.m back|carry on where we left off/.test(text)) {
    land(home);
    clean(home);
    return;
  }
  if (/implement|same worker|promote/.test(text)) {
    promote(home);
    land(home);
    clean(home);
  }
}

function extractOrigin(text) {
  const m = text.match(/from\s+(\S+)\s+as/i);
  return m ? m[1] : null;
}

export class FakeHerdrServer {
  constructor({ socketPath, journal, origin } = {}) {
    this.socketPath = socketPath;
    this.journal = journal;
    this.origin = origin || null;
    this.home = null;
    this.paneText = "";
    this.agentStatus = "idle";
    this.says = [];
    this.server = null;
    this.n = 0;
    this.calls = 0;
  }

  start() {
    return new Promise((resolve, reject) => {
      this.server = createServer((sock) => this.onConn(sock));
      this.server.on("error", reject);
      this.server.listen(this.socketPath, () => resolve());
    });
  }

  close() {
    return new Promise((resolve) => {
      if (!this.server) return resolve();
      this.server.close(() => resolve());
    });
  }

  onConn(sock) {
    let buf = "";
    sock.setEncoding("utf8");
    sock.on("data", (chunk) => {
      buf += chunk;
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (!line.trim()) continue;
        let req;
        try {
          req = JSON.parse(line);
        } catch {
          continue;
        }
        const result = this.handle(req);
        sock.write(JSON.stringify({ id: req.id, result }) + "\n");
      }
    });
  }

  handle(req) {
    this.calls += 1;
    const method = req.method;
    const params = req.params || {};
    journalLine(this.journal, { method, params });
    if (method === "workspace.create") {
      this.home = params.cwd;
      return {
        type: "workspace_created",
        workspace: { workspace_id: "w1" },
        root_pane: { pane_id: "w1:p1", agent_status: "idle" },
        tab: { tab_id: "w1:t1" },
      };
    }
    if (method === "workspace.close" || method === "workspace.focus") {
      return { type: "ok" };
    }
    if (method === "pane.send_input" || method === "pane.send_text") {
      const text = params.text || "";
      if (text && text !== "/exit" && !/claude/.test(text)) {
        this.says.push(text);
      }
      if (text.includes("claude") && text.includes("dangerously-skip-permissions")) {
        this.paneText = "bypass permissions on\n";
        this.agentStatus = "working";
      }
      if (text === "/exit") {
        this.paneText = "$ ";
        this.agentStatus = "idle";
      }
      const origin = this.origin || extractOrigin(text);
      if (origin) this.origin = origin;
      applyCaptainText(this.home, text, this.origin);
      return { type: "ok" };
    }
    if (method === "pane.send_keys") return { type: "ok" };
    if (method === "pane.read") {
      const text = this.paneText || "bypass permissions on\n";
      return { type: "pane_read", read: { text, source: "recent_unwrapped" }, text };
    }
    if (method === "pane.get") {
      return { pane: { pane_id: "w1:p1", agent_status: this.agentStatus } };
    }
    if (method === "pane.wait_for_output") {
      return { matched: false };
    }
    return { type: "ok" };
  }
}

export function writeFakeJournalSays(journal) {
  if (!journal || !existsSync(journal)) return [];
  return readFileSync(journal, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l))
    .filter((e) => e.method === "pane.send_input" || e.method === "pane.send_text")
    .map((e) => e.params?.text || "")
    .filter((t) => t && t !== "/exit" && !/claude/.test(t));
}

const invoked = process.argv[1] && process.argv[1].endsWith("fake-herdr.mjs");
if (invoked && process.argv[2] === "--serve") {
  const args = process.argv.slice(2);
  const socket = args[args.indexOf("--socket") + 1];
  const journal = args.includes("--journal") ? args[args.indexOf("--journal") + 1] : null;
  const origin = args.includes("--origin") ? args[args.indexOf("--origin") + 1] : null;
  const server = new FakeHerdrServer({ socketPath: socket, journal, origin });
  await server.start();
  process.stdout.write(`listening ${socket}\n`);
  const stop = () => server.close().then(() => process.exit(0));
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
}
