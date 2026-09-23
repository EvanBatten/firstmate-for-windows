import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { HerdrClient, READY_BANNER, TRUST } from "./herdr.mjs";
import { interpolateTrace, isReservedSay } from "./trace.mjs";
import { waitUntil } from "./wait.mjs";

const here = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = join(here, "..", "..", "..");

function git(cwd, args) {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

function paneEnv() {
  const env = {};
  for (const key of ["HOME", "USER", "TERM", "USERPROFILE", "LOCALAPPDATA", "APPDATA"]) {
    if (process.env[key]) env[key] = process.env[key];
  }
  // The clone is the home (cwd). A separate FM_HOME makes some herdr
  // builds keep sessions under that path, and a primary /exit then
  // looks like it took the worker with it.
  const oauth = process.env.CLAUDE_CODE_OAUTH_TOKEN;
  const oath = process.env.CLAUDE_CODE_OATH_TOKEN;
  if (oauth) env.CLAUDE_CODE_OAUTH_TOKEN = oauth;
  else if (oath) env.CLAUDE_CODE_OAUTH_TOKEN = oath;
  const extra = [];
  if (process.env.HOME) extra.push(join(process.env.HOME, ".local", "bin"));
  if (process.env.FM_CONTROL_PATH_EXTRA) extra.push(process.env.FM_CONTROL_PATH_EXTRA);
  if (process.env.VERIFY_PANE_PATH_EXTRA) extra.push(process.env.VERIFY_PANE_PATH_EXTRA);
  env.PATH = [...extra, process.env.PATH || ""].filter(Boolean).join(process.platform === "win32" ? ";" : ":");
  return env;
}

function claudeLaunch(model, envFile) {
  const bin = process.platform === "win32" ? "claude.exe" : "claude";
  const cmd = `${bin} --dangerously-skip-permissions --model ${model}`;
  if (!envFile) return cmd;
  if (process.platform === "win32") {
    const quoted = envFile.replace(/'/g, "''");
    return `$env:CLAUDE_CODE_OAUTH_TOKEN = (Get-Content -LiteralPath '${quoted}' -Raw).Trim(); Remove-Item -LiteralPath '${quoted}' -Force; ${cmd}`;
  }
  return `IFS= read -r CLAUDE_CODE_OAUTH_TOKEN < .fm-control-env; export CLAUDE_CODE_OAUTH_TOKEN; rm -f .fm-control-env; ${cmd}`;
}

function mergeClaudeOnboarding(home) {
  const dest = join(process.env.HOME || "", ".claude.json");
  if (!process.env.HOME) return;
  let current = {};
  try {
    current = JSON.parse(readFileSync(dest, "utf8"));
  } catch {
    current = {};
  }
  if (!current || typeof current !== "object") current = {};
  current.hasCompletedOnboarding = true;
  if (!current.lastOnboardingVersion) current.lastOnboardingVersion = "2.1.280";
  if (!current.projects || typeof current.projects !== "object") current.projects = {};
  const key = home;
  current.projects[key] = {
    ...(current.projects[key] || {}),
    hasTrustDialogAccepted: true,
  };
  writeFileSync(dest, JSON.stringify(current, null, 2) + "\n", { mode: 0o600 });
}

function writePaneEnvFile(home) {
  const token = process.env.CLAUDE_CODE_OAUTH_TOKEN || process.env.CLAUDE_CODE_OATH_TOKEN || "";
  if (!token) return null;
  const dest = join(home, ".fm-control-env");
  writeFileSync(dest, token.endsWith("\n") ? token : `${token}\n`, { mode: 0o600 });
  return dest;
}

export function seedProject(scratch, name = "greeter") {
  const origin = join(scratch, `${name}.git`);
  const seed = join(scratch, `${name}-seed`);
  execFileSync("git", ["init", "-q", "--bare", "-b", "main", origin]);
  execFileSync("git", ["clone", "-q", origin, seed]);
  git(seed, ["config", "user.email", "verify@example.invalid"]);
  git(seed, ["config", "user.name", "verification"]);
  git(seed, ["config", "core.autocrlf", "false"]);
  try {
    git(seed, ["checkout", "-q", "-b", "main"]);
  } catch {
    /* already on main */
  }
  writeFileSync(
    join(seed, "README.md"),
    `# ${name}\n\nA throwaway project for a firstmate verification session.\n`,
  );
  git(seed, ["add", "-A"]);
  git(seed, ["commit", "-qm", `start the ${name} project`]);
  git(seed, ["push", "-q", "-u", "origin", "main"]);
  const base = git(origin, ["rev-parse", "main"]);
  rmSync(seed, { recursive: true, force: true });
  return { origin, base };
}

export function cloneHome(repoRoot, dest) {
  const sha = git(repoRoot, ["rev-parse", "HEAD"]);
  let branch = "HEAD";
  try {
    branch = git(repoRoot, ["rev-parse", "--abbrev-ref", "HEAD"]);
  } catch {
    branch = "HEAD";
  }
  if (branch === "HEAD") {
    execFileSync("git", ["clone", "-q", "-c", "core.symlinks=true", repoRoot, dest]);
    git(dest, ["checkout", "-q", sha]);
  } else {
    execFileSync("git", [
      "clone",
      "-q",
      "-c",
      "core.symlinks=true",
      "--branch",
      branch,
      repoRoot,
      dest,
    ]);
  }
  const porcelain = execFileSync("git", ["status", "--porcelain"], {
    cwd: repoRoot,
    encoding: "utf8",
  });
  if (porcelain.trim()) {
    try {
      const diff = execFileSync("git", ["diff", "HEAD", "--binary"], { cwd: repoRoot });
      if (diff.length) {
        execFileSync("git", ["apply"], { cwd: dest, input: diff });
      }
    } catch {
      /* clone is SHA exactly */
    }
  }
}

export class Session {
  constructor(opts = {}) {
    this.feature = opts.feature || "session";
    this.model = opts.model || process.env.FM_CONTROL_MODEL || process.env.VERIFY_SESSION_MODEL || "sonnet";
    this.repoRoot = opts.repoRoot || process.env.FM_CONTROL_REPO || REPO_ROOT;
    this.herdr = opts.herdr || new HerdrClient({ sessionName: `fm-ctl-${process.pid}-${this.feature}` });
    this.scratch = null;
    this.home = null;
    this.workspaceId = null;
    this.paneId = null;
    this.createdWorkspace = false;
    this.projectSeeds = {};
    this.projectOrigin = null;
    this.lockAtReady = null;
    this.lockBeforeRelaunch = null;
    this.readyAtMs = null;
    this.closed = false;
    this.lastDeadCheck = 0;
    this.paneEnvFile = null;
    this.deadMonitor = null;
  }

  stamps() {
    return {
      lockAtReady: this.lockAtReady,
      lockBeforeRelaunch: this.lockBeforeRelaunch,
      projectSeeds: this.projectSeeds,
    };
  }

  async open() {
    this.scratch = mkdtempSync(join(tmpdir(), `fm-control-${this.feature}-`));
    this.home = join(this.scratch, "firstmate");
    cloneHome(this.repoRoot, this.home);
    const seeded = seedProject(this.scratch, "greeter");
    this.projectOrigin = seeded.origin;
    this.projectSeeds.greeter = seeded.base;
    this.paneEnvFile = writePaneEnvFile(this.home);
    mergeClaudeOnboarding(this.home);
    await this.herdr.connect();
    const created = await this.herdr.workspaceCreate({
      cwd: this.home,
      label: `fm-control-${this.feature}`,
      env: paneEnv(),
    });
    this.workspaceId = created.workspaceId;
    this.paneId = created.paneId;
    this.createdWorkspace = true;
  }

  async launchClaude() {
    this.herdr.dead = false;
    await this.herdr.paneRun(this.paneId, claudeLaunch(this.model));
  }

  async ready(budgetMs = Number(process.env.FM_CONTROL_READY_MS || 180_000)) {
    const deadline = Date.now() + budgetMs;
    while (Date.now() < deadline) {
      let text = "";
      try {
        text = await this.herdr.paneRead(this.paneId, 80);
      } catch {
        text = "";
      }
      if (text.includes(READY_BANNER)) {
        try {
          this.lockAtReady = readFileSync(join(this.home, "state", ".lock"), "utf8");
        } catch {
          this.lockAtReady = this.lockAtReady || `ready-${Date.now()}`;
        }
        this.readyAtMs = Date.now();
        this.herdr.dead = false;
        this.startDeadMonitor();
        return;
      }
      if (/Choose the text style|Dark mode \(colorblind|\/theme/.test(text)) {
        await this.herdr.paneSendKeys(this.paneId, ["enter"]);
        await new Promise((r) => setTimeout(r, 300));
        continue;
      }
      if (/Paste code here if prompted/.test(text)) {
        throw new Error("primary asked to paste an OAuth code; token did not authenticate the pane");
      }
      if (/Select login method|Claude account with subscription/.test(text)) {
        throw new Error("primary is still in first-run login; ~/.claude.json onboarding seed did not take");
      }
      if (/Bypass Permissions mode|Yes, I accept/.test(text) && /No, exit/.test(text)) {
        await this.herdr.paneSendKeys(this.paneId, ["down"]);
        await new Promise((r) => setTimeout(r, 200));
        await this.herdr.paneSendKeys(this.paneId, ["enter"]);
        await new Promise((r) => setTimeout(r, 400));
        continue;
      }
      if (text.includes(TRUST) || /Do you trust the files|trust this folder/.test(text)) {
        await this.herdr.paneSendKeys(this.paneId, ["down"]);
        await new Promise((r) => setTimeout(r, 200));
        try {
          const again = await this.herdr.paneRead(this.paneId, 40);
          if (/❯ *Yes/.test(again) || /Yes, I trust|trust this folder/.test(again)) {
            await this.herdr.paneSendKeys(this.paneId, ["enter"]);
          }
        } catch {
          await this.herdr.paneSendKeys(this.paneId, ["enter"]);
        }
        await new Promise((r) => setTimeout(r, 300));
        continue;
      }
      if (this.herdr.atShellPrompt(text) && /claude --dangerously/.test(text) && !/Welcome to Claude/.test(text)) {
        throw new Error("primary exited before ready");
      }
      await new Promise((r) => setTimeout(r, 200));
    }
    throw new Error("primary did not become ready");
  }

  startDeadMonitor() {
    this.stopDeadMonitor();
    this.deadMonitor = setInterval(() => {
      if (!this.paneId) return;
      this.herdr.refreshDead(this.paneId).catch(() => {
        this.herdr.dead = true;
      });
    }, 1000);
    if (typeof this.deadMonitor.unref === "function") this.deadMonitor.unref();
  }

  stopDeadMonitor() {
    if (this.deadMonitor) clearInterval(this.deadMonitor);
    this.deadMonitor = null;
  }

  isDead() {
    return this.herdr.dead;
  }

  async say(text) {
    if (!text) return;
    if (text === "$relaunch") {
      await this.relaunch();
      return;
    }
    if (text === "$exit") {
      await this.exitToPrompt();
      return;
    }
    try {
      const status = await this.herdr.paneGet(this.paneId);
      const agent = status?.pane?.agent_status || status?.agent_status;
      if (agent === "blocked") {
        await this.herdr.paneSendKeys(this.paneId, ["esc"]);
        await new Promise((r) => setTimeout(r, 200));
      }
    } catch {
      /* type anyway */
    }
    try {
      await this.herdr.workspaceFocus(this.workspaceId);
    } catch {
      /* focus is best-effort */
    }
    await this.herdr.paneRun(this.paneId, text);
  }

  async exitToPrompt(budgetMs = 90_000) {
    let already = "";
    try {
      already = await this.herdr.paneRead(this.paneId, 8);
    } catch {
      already = "";
    }
    if (this.herdr.atShellPrompt(already)) return;
    await this.herdr.paneRun(this.paneId, "/exit");
    const deadline = Date.now() + budgetMs;
    let confirmed = false;
    while (Date.now() < deadline) {
      const text = await this.herdr.paneRead(this.paneId, 40);
      if (this.herdr.atShellPrompt(text)) return;
      if (!confirmed && text.includes("Background work is running")) {
        await this.herdr.paneSendKeys(this.paneId, ["enter"]);
        confirmed = true;
      }
      await new Promise((r) => setTimeout(r, 250));
    }
    throw new Error("primary did not exit on /exit");
  }

  async relaunch() {
    try {
      this.lockBeforeRelaunch = readFileSync(join(this.home, "state", ".lock"), "utf8");
    } catch {
      this.lockBeforeRelaunch = this.lockAtReady;
    }
    await this.exitToPrompt();
    this.herdr.dead = false;
    await this.launchClaude();
    await this.ready();
  }

  async wait(until, budgetMs) {
    return waitUntil({
      home: this.home,
      until,
      budgetMs,
      stamps: this.stamps(),
      isDead: () => this.isDead(),
    });
  }

  stopWatcher() {
    try {
      const pid = readFileSync(join(this.home, "state", ".watch.lock", "pid"), "utf8").trim();
      if (/^\d+$/.test(pid)) process.kill(Number(pid));
    } catch {
      /* none */
    }
  }

  destroyPools() {
    const root = join(process.env.HOME || "", ".treehouse");
    if (!this.home || !existsSync(root)) return;
    let pools = [];
    try {
      pools = readdirSync(root);
    } catch {
      return;
    }
    for (const name of pools) {
      const pool = join(root, name);
      if (!this.poolBelongsHere(pool)) continue;
      try {
        execFileSync("treehouse", ["destroy", pool, "--all", "--include-unlanded", "--include-in-use", "--yes"], {
          timeout: 20_000,
          stdio: "ignore",
        });
      } catch {
        rmSync(pool, { recursive: true, force: true });
      }
    }
  }

  poolBelongsHere(pool) {
    const stack = [pool];
    let depth = 0;
    while (stack.length && depth < 64) {
      const dir = stack.pop();
      depth += 1;
      let kids = [];
      try {
        kids = readdirSync(dir);
      } catch {
        continue;
      }
      if (kids.includes(".git") || existsSync(join(dir, ".git"))) {
        try {
          const common = execFileSync(
            "git",
            ["-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            { encoding: "utf8" },
          ).trim();
          if (common === this.home || common.startsWith(`${this.home}/`)) return true;
        } catch {
          /* not a repo */
        }
      }
      for (const kid of kids) {
        if (kid === ".git" || kid === "node_modules") continue;
        const p = join(dir, kid);
        try {
          if (statSync(p).isDirectory()) stack.push(p);
        } catch {
          /* ignore */
        }
      }
    }
    return false;
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    this.stopDeadMonitor();
    try {
      if (this.paneId && !this.herdr.atShellPrompt()) {
        await this.exitToPrompt().catch(() => {});
      }
    } catch {
      /* ignore */
    }
    this.stopWatcher();
    this.destroyPools();
    if (this.createdWorkspace && this.workspaceId) {
      await this.herdr.workspaceClose(this.workspaceId);
    }
    await this.herdr.close({ stopSession: this.herdr.startedServer });
    if (this.scratch && process.env.FM_CONTROL_KEEP !== "1") {
      rmSync(this.scratch, { recursive: true, force: true });
    }
  }
}

export function defaultBudgetSec(until) {
  if (until.startsWith("landed") || until.startsWith("git-ahead") || until.startsWith("reported")) {
    return Number(process.env.FM_CONTROL_UNTIL_SEC || 1200);
  }
  if (until === "dispatched" || until.startsWith("meta-count") || until === "promoted") return 900;
  return 600;
}

