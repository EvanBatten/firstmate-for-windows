import { EventEmitter } from "node:events";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  watch,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { delimiter, dirname, join, relative, resolve } from "node:path";
import { createHash } from "node:crypto";
import { deflateSync } from "node:zlib";
import { fileURLToPath } from "node:url";
import { HerdrController } from "./controller.mjs";
import {
  lockIdentity,
  waitForPredicate,
  watcherPid,
} from "./home.mjs";
import { interpolateTrace } from "./trace.mjs";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const PRIVATE_ROOTS = new Set(["data", "state", "config", "projects", ".no-mistakes"]);

function gitObject(gitDir, type, body) {
  const payload = Buffer.isBuffer(body) ? body : Buffer.from(body);
  const object = Buffer.concat([Buffer.from(`${type} ${payload.length}\0`), payload]);
  const sha = createHash("sha1").update(object).digest("hex");
  const path = join(gitDir, "objects", sha.slice(0, 2), sha.slice(2));
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, deflateSync(object));
  return sha;
}

function seedBareProject(path) {
  mkdirSync(join(path, "objects"), { recursive: true });
  mkdirSync(join(path, "refs", "heads"), { recursive: true });
  writeFileSync(join(path, "HEAD"), "ref: refs/heads/main\n");
  writeFileSync(
    join(path, "config"),
    "[core]\n\trepositoryformatversion = 0\n\tbare = true\n",
  );
  const readme = Buffer.from("# greeter\n\nA throwaway project for a firstmate control trace.\n");
  const blob = gitObject(path, "blob", readme);
  const treeBody = Buffer.concat([
    Buffer.from("100644 README.md\0"),
    Buffer.from(blob, "hex"),
  ]);
  const tree = gitObject(path, "tree", treeBody);
  const identity = "verification <verify@example.invalid> 0 +0000";
  const commit = gitObject(
    path,
    "commit",
    `tree ${tree}\nauthor ${identity}\ncommitter ${identity}\n\nstart greeter\n`,
  );
  writeFileSync(join(path, "refs", "heads", "main"), `${commit}\n`);
  return commit;
}

function prepareCopiedHome(feature) {
  const scratch = mkdtempSync(join(tmpdir(), `fm-control-${feature}-`));
  const home = join(scratch, "firstmate");
  cpSync(REPO_ROOT, home, {
    recursive: true,
    verbatimSymlinks: true,
    filter(source) {
      const rel = relative(REPO_ROOT, source);
      if (!rel) return true;
      const root = rel.split(/[\\/]/, 1)[0];
      return !PRIVATE_ROOTS.has(root);
    },
  });
  for (const directory of ["data", "state", "config", "projects"]) {
    mkdirSync(join(home, directory), { recursive: true });
  }
  writeFileSync(join(home, ".fm-control-throwaway"), "created by fm-control\n");
  return { scratch, home, owned: true };
}

function prepareHome(feature, environment) {
  if (!environment.FM_CONTROL_HOME) return prepareCopiedHome(feature);
  const home = resolve(environment.FM_CONTROL_HOME);
  if (!existsSync(join(home, ".fm-control-throwaway"))) {
    throw new Error("FM_CONTROL_HOME is not marked as a throwaway home");
  }
  for (const directory of ["data", "state", "config", "projects"]) {
    mkdirSync(join(home, directory), { recursive: true });
  }
  return { scratch: dirname(home), home, owned: false };
}

function paneEnvironment(home, environment) {
  const localBin = join(homedir(), ".local", "bin");
  const tools = join(home, ".tools", "node_modules", ".bin");
  const path = [tools, localBin, environment.PATH || ""].filter(Boolean).join(delimiter);
  const result = { PATH: path };
  const oauth = environment.CLAUDE_CODE_OAUTH_TOKEN ||
    environment.CLAUDE_CODE_OATH_TOKEN;
  if (oauth) result.CLAUDE_CODE_OAUTH_TOKEN = oauth;
  for (const name of ["HOME", "USER", "USERNAME", "TEMP", "TMP", "LOCALAPPDATA", "APPDATA"]) {
    if (environment[name]) result[name] = environment[name];
  }
  return result;
}

function eventText(event) {
  return String(event?.data?.matched_line || "");
}

export class Session {
  constructor({ trace, environment = process.env, metrics }) {
    this.originalTrace = trace;
    this.environment = { ...environment };
    if (!this.environment.CLAUDE_CODE_OAUTH_TOKEN &&
        this.environment.CLAUDE_CODE_OATH_TOKEN) {
      this.environment.CLAUDE_CODE_OAUTH_TOKEN =
        this.environment.CLAUDE_CODE_OATH_TOKEN;
    }
    this.metrics = metrics;
    this.failures = new EventEmitter();
    this.prepared = null;
    this.trace = null;
    this.controller = null;
    this.workspaceId = null;
    this.paneId = null;
    this.readyAt = null;
    this.readyMs = 0;
    this.bannerReady = false;
    this.readyWait = null;
    this.readyTimer = null;
    this.readyWatcher = null;
    this.lockBefore = null;
    this.relaunching = false;
    this.relaunchStarted = false;
    this.running = false;
    this.closed = false;
    this.projectSeeds = {};
  }

  async open(startedAt) {
    this.prepared = prepareHome(this.originalTrace.feature, this.environment);
    const origin = join(this.prepared.scratch, "greeter.git");
    rmSync(origin, { recursive: true, force: true });
    this.projectSeeds.greeter = seedBareProject(origin);
    this.trace = interpolateTrace(this.originalTrace, {
      projectOrigin: origin,
      home: this.prepared.home,
    });
    this.controller = new HerdrController({
      env: this.environment,
      home: this.prepared.home,
      metrics: this.metrics,
    });
    this.controller.on("event", (event) => this.handleEvent(event));
    this.controller.on("failure", (error) => {
      this.failures.emit("failure", `Herdr server failed: ${error.message}`);
    });
    await this.controller.connect();
    const result = await this.controller.request("workspace.create", {
      cwd: this.prepared.home,
      label: `fm-control-${this.trace.feature}`,
      focus: false,
      env: paneEnvironment(this.prepared.home, this.environment),
    });
    this.workspaceId = result?.workspace?.workspace_id;
    this.paneId = result?.root_pane?.pane_id;
    if (!this.workspaceId || !this.paneId) {
      throw new Error("Herdr workspace create returned no pane");
    }
    await this.controller.subscribe(this.paneId);
    await this.launchAndReady(null);
    this.readyAt = Date.now();
    this.readyMs = this.readyAt - startedAt;
  }

  launchCommand() {
    const model = this.environment.FM_CONTROL_MODEL || "opus";
    if (!/^[A-Za-z0-9._:-]+$/.test(model)) throw new Error("invalid FM_CONTROL_MODEL");
    const executable = process.platform === "win32" ? "claude.exe" : "claude";
    return `${executable} --dangerously-skip-permissions --model ${model}`;
  }

  async launchAndReady(previousLock) {
    this.bannerReady = false;
    const ready = new Promise((resolveReady, rejectReady) => {
      this.readyWait = { resolve: resolveReady, reject: rejectReady, previousLock };
      this.readyWatcher = watch(this.prepared.home, { recursive: true }, () => {
        this.checkReady();
      });
      this.readyTimer = setTimeout(() => {
        this.readyWatcher?.close();
        this.readyWatcher = null;
        this.readyWait = null;
        rejectReady(new Error("primary readiness deadline exceeded"));
      }, Number(this.environment.FM_CONTROL_READY_MS || 180000));
    });
    this.running = true;
    await this.controller.sendInput(this.paneId, this.launchCommand());
    this.checkReady();
    return ready;
  }

  checkReady() {
    if (!this.readyWait || !this.bannerReady) return;
    const current = lockIdentity(this.prepared.home);
    if (current === null) return;
    if (this.readyWait.previousLock !== null && current === this.readyWait.previousLock) {
      return;
    }
    clearTimeout(this.readyTimer);
    this.readyWatcher?.close();
    this.readyWatcher = null;
    const resolveReady = this.readyWait.resolve;
    this.readyWait = null;
    resolveReady(current);
  }

  async beginRelaunch() {
    this.lockBefore = lockIdentity(this.prepared.home);
    this.relaunching = true;
    this.relaunchStarted = false;
    this.running = false;
    const ready = new Promise((resolveReady, rejectReady) => {
      this.readyWait = {
        resolve: (identity) => {
          this.relaunching = false;
          this.running = true;
          resolveReady(identity);
        },
        reject: rejectReady,
        previousLock: this.lockBefore,
      };
      this.readyWatcher = watch(this.prepared.home, { recursive: true }, () => {
        this.checkReady();
      });
      this.readyTimer = setTimeout(() => {
        this.readyWatcher?.close();
        this.readyWatcher = null;
        this.readyWait = null;
        rejectReady(new Error("primary relaunch deadline exceeded"));
      }, Number(this.environment.FM_CONTROL_READY_MS || 180000));
    });
    this.bannerReady = false;
    await this.controller.sendInput(this.paneId, "/exit");
    await ready;
  }

  async restartAtPrompt() {
    if (!this.relaunching || this.relaunchStarted) return;
    this.relaunchStarted = true;
    await this.controller.sendInput(this.paneId, this.launchCommand());
  }

  handleEvent(event) {
    if (event.event === "pane.output_matched") {
      const text = eventText(event);
      if (text.includes("Choose the text style that looks best")) {
        this.controller.sendKeys(this.paneId, ["enter"]).catch((error) => {
          this.failures.emit("failure", `could not accept Claude theme: ${error.message}`);
        });
      }
      if (text.includes("Select login method") &&
          this.environment.CLAUDE_CODE_OAUTH_TOKEN) {
        this.controller.sendKeys(this.paneId, ["enter"]).catch((error) => {
          this.failures.emit("failure", `could not select Claude OAuth login: ${error.message}`);
        });
      }
      if (text.includes("Yes, I trust this folder")) {
        this.controller.sendKeys(this.paneId, ["down", "enter"]).catch((error) => {
          this.failures.emit("failure", `could not accept folder trust: ${error.message}`);
        });
      }
      if (text.includes("Background work is running") && this.relaunching) {
        this.controller.sendKeys(this.paneId, ["enter"]).catch((error) => {
          this.failures.emit("failure", `could not confirm primary exit: ${error.message}`);
        });
      }
      if (text.includes("bypass permissions on")) {
        this.bannerReady = true;
        this.checkReady();
      }
      if (this.relaunching && /[$#>]\s*$/.test(text)) {
        this.restartAtPrompt().catch((error) => {
          this.failures.emit("failure", `could not restart primary: ${error.message}`);
        });
      }
      return;
    }
    if (event.event !== "pane.agent_status_changed") return;
    const status = event?.data?.agent_status;
    if (this.relaunching && status === "unknown") {
      this.restartAtPrompt().catch((error) => {
        this.failures.emit("failure", `could not restart primary: ${error.message}`);
      });
      return;
    }
    if (this.running && !this.readyWait &&
        (status === "unknown" || status === "blocked")) {
      const reason = status === "blocked"
        ? "primary stopped for an unanswered decision"
        : "primary exited";
      this.failures.emit("failure", reason);
    }
  }

  async performSay(say) {
    if (say === "$relaunch") {
      await this.beginRelaunch();
      return;
    }
    if (!say) return;
    await this.controller.request("workspace.focus", { workspace_id: this.workspaceId });
    await this.controller.sendInput(this.paneId, say);
  }

  async wait(step) {
    const context = {
      lockBefore: this.lockBefore,
      projectSeeds: this.projectSeeds,
    };
    return waitForPredicate({
      home: this.prepared.home,
      parsed: step.parsedUntil,
      context,
      budgetMs: step.budgetSec * 1000,
      failureEmitter: this.failures,
    });
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    this.running = false;
    clearTimeout(this.readyTimer);
    this.readyWatcher?.close();
    try {
      if (this.paneId) await this.controller?.sendInput(this.paneId, "/exit");
    } catch {}
    const pid = this.prepared ? watcherPid(this.prepared.home) : null;
    if (pid) {
      try {
        process.kill(pid, "SIGTERM");
      } catch {}
    }
    try {
      if (this.workspaceId) {
        await this.controller?.request(
          "workspace.close",
          { workspace_id: this.workspaceId },
          10000,
        );
      }
    } catch {}
    await this.controller?.close();
    if (this.prepared?.owned && this.environment.FM_CONTROL_KEEP !== "1") {
      rmSync(this.prepared.scratch, { recursive: true, force: true });
    }
  }
}
