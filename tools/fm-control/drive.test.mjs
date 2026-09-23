import assert from "node:assert/strict";
import {
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { evaluatePredicate, snapshotHome } from "./lib/home.mjs";
import { prepareCopiedHome } from "./lib/session.mjs";
import { parseUntil } from "./lib/trace.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const DRIVE = join(ROOT, "tools", "fm-control", "drive.mjs");
const FAKE = join(ROOT, "tools", "fm-control", "test", "fake-herdr.mjs");
const RESTART = join(ROOT, "tools", "fm-control", "traces", "restart-primary.json");

function temporaryHome(prefix) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  const home = join(root, "home");
  for (const directory of ["data", "state", "config", "projects"]) {
    mkdirSync(join(home, directory), { recursive: true });
  }
  writeFileSync(join(home, ".fm-control-throwaway"), "test\n");
  return { root, home };
}

function runDriver(trace, env = {}) {
  return spawnSync(process.execPath, [DRIVE, "run", trace], {
    cwd: ROOT,
    encoding: "utf8",
    env: { ...process.env, ...env },
    timeout: 30000,
  });
}

test("rejects unknown and startup-only traces before spawning Herdr", () => {
  for (const [name, value] of [
    ["unknown", { feature: "bad", steps: [{ say: "go", until: "not-real" }] }],
    ["pong", { feature: "bad", steps: [{ say: "go", until: "pong" }] }],
    ["lock", { feature: "bad", steps: [{ say: "go", until: "lock-held" }] }],
  ]) {
    const { root, home } = temporaryHome(`fm-control-reject-${name}-`);
    const trace = join(root, "trace.json");
    const log = join(root, "fake.log");
    writeFileSync(trace, JSON.stringify(value));
    const result = runDriver(trace, {
      FM_CONTROL_HOME: home,
      FM_CONTROL_FAKE_HERDR: FAKE,
      FM_CONTROL_FAKE_LOG: log,
    });
    assert.equal(result.status, 2, result.stderr);
    assert.equal(result.stdout, "");
    assert.throws(() => readFileSync(log), /ENOENT/);
  }
});

test("home predicates return literal booleans over fixtures", () => {
  const { home } = temporaryHome("fm-control-predicates-");
  mkdirSync(join(home, "projects", "greeter", ".git", "refs", "heads"), {
    recursive: true,
  });
  mkdirSync(join(home, "data", "task"), { recursive: true });
  writeFileSync(join(home, "data", "projects.md"), "- greeter local-only yolo=off\n");
  writeFileSync(join(home, "data", "task", "report.md"), "A report.\n");
  writeFileSync(join(home, "state", "task.meta"), "kind=scout\n");
  writeFileSync(join(home, "state", "task.status"), "working: investigating\n");
  writeFileSync(join(home, "state", ".lock"), "new-lock\n");
  writeFileSync(join(home, "state", ".wake-queue"), "");
  writeFileSync(
    join(home, "projects", "greeter", ".git", "refs", "heads", "main"),
    `${"b".repeat(40)}\n`,
  );

  const context = {
    lockBefore: "file:old-lock\n",
    projectSeeds: { greeter: "a".repeat(40) },
  };
  const snapshot = snapshotHome(home, context);
  for (const [token, expected] of [
    ["project-registered:greeter", true],
    ["task-count:1", true],
    ["task-count:2", false],
    ["task-kind:scout", true],
    ["task-kind:ship", false],
    ["status-verb:working", true],
    ["status-verb:done", false],
    ["report-exists", true],
    ["lock-rotated", true],
    ["git-ahead:greeter:1", true],
    ["clean-home", false],
    ["wake-empty", true],
  ]) {
    const actual = evaluatePredicate(snapshot, parseUntil(token), context);
    assert.equal(typeof actual, "boolean", token);
    assert.equal(actual, expected, token);
  }
});

test("copied homes materialize the tracked skill link", () => {
  const prepared = prepareCopiedHome("copy-portable");
  try {
    const skills = join(prepared.home, ".claude", "skills");
    assert.equal(lstatSync(skills).isDirectory(), true);
    assert.equal(lstatSync(skills).isSymbolicLink(), false);
    assert.equal(
      lstatSync(join(skills, "control-firstmate", "SKILL.md")).isFile(),
      true,
    );
  } finally {
    rmSync(prepared.scratch, { recursive: true, force: true });
  }
});

test("blocked decisions fail with a reason and cleanup cancels them", () => {
  const { root, home } = temporaryHome("fm-control-blocked-");
  const trace = join(root, "trace.json");
  const log = join(root, "fake.log");
  writeFileSync(trace, JSON.stringify({
    feature: "blocked",
    steps: [{ say: "trigger a decision", until: "project-registered:greeter" }],
  }));
  const result = runDriver(trace, {
    FM_CONTROL_HOME: home,
    FM_CONTROL_FAKE_HERDR: FAKE,
    FM_CONTROL_FAKE_LOG: log,
    FM_CONTROL_FAKE_BLOCKED: "1",
    FM_CONTROL_READY_MS: "5000",
  });
  assert.equal(result.status, 1, result.stderr);
  const output = JSON.parse(result.stdout);
  assert.deepEqual(output.steps.map((step) => ({
    until: step.until,
    ok: step.ok,
    reason: step.reason,
  })), [{
    until: "project-registered:greeter",
    ok: false,
    reason: "primary stopped for an unanswered decision",
  }]);
  const sent = readFileSync(log, "utf8").trim().split("\n").map(JSON.parse);
  assert.deepEqual(sent, ["trigger a decision", "$decision-cancelled"]);
});

test("fake Herdr drives restart trace and sends each captain say once", () => {
  const { root, home } = temporaryHome("fm-control-e2e-");
  const log = join(root, "fake.log");
  const result = runDriver(RESTART, {
    FM_CONTROL_HOME: home,
    FM_CONTROL_FAKE_HERDR: FAKE,
    FM_CONTROL_FAKE_LOG: log,
    FM_CONTROL_READY_MS: "5000",
    CLAUDE_CODE_OAUTH_TOKEN: "not-a-real-token",
  });
  assert.equal(result.status, 0, result.stderr);
  const output = JSON.parse(result.stdout);
  assert.equal(output.feature, "restart-primary");
  assert.equal(output.pass, true);
  assert.equal(output.steps.length, 5);
  assert.equal(output.steps.every((step) => step.ok === true), true);
  assert.deepEqual(output.overhead, { herdrCalls: 1, spawns: 1 });
  for (const field of ["wallMs", "readyMs", "predicateMs"]) {
    assert.equal(typeof output[field], "number");
  }

  const trace = JSON.parse(readFileSync(RESTART, "utf8"));
  const expected = trace.steps
    .map((step) => step.say)
    .filter((say) => say && !say.startsWith("$"))
    .map((say) => say.replaceAll("{{projectOrigin}}", join(root, "greeter.git"))
      .replaceAll("{{home}}", home));
  const sent = readFileSync(log, "utf8").trim().split("\n").map(JSON.parse);
  assert.deepEqual(sent, expected);
  assert.equal(sent.includes("$relaunch"), false);

  const config = join(home, ".fm-control-claude");
  const global = JSON.parse(readFileSync(join(config, ".claude.json"), "utf8"));
  const settings = JSON.parse(readFileSync(join(config, "settings.json"), "utf8"));
  assert.deepEqual(global, {
    hasCompletedOnboarding: true,
    bypassPermissionsModeAccepted: true,
    projects: {
      [home]: { hasTrustDialogAccepted: true },
    },
  });
  assert.deepEqual(settings, { theme: "dark" });
  assert.equal(
    `${readFileSync(join(config, ".claude.json"))}${readFileSync(join(config, "settings.json"))}`
      .includes("not-a-real-token"),
    false,
  );
});
