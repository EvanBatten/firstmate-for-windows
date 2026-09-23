import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { snapshotHome } from "../lib/snapshot.mjs";
import { evaluateUntil } from "../lib/predicates.mjs";

function home(name) {
  const dir = join(tmpdir(), `fm-control-pred-${name}-${process.pid}`);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(join(dir, "state"), { recursive: true });
  mkdirSync(join(dir, "data"), { recursive: true });
  mkdirSync(join(dir, "projects"), { recursive: true });
  return dir;
}

function gitInit(dir) {
  execFileSync("git", ["init", "-q", "-b", "main", dir]);
  execFileSync("git", ["config", "user.email", "t@example.invalid"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "t"], { cwd: dir });
  writeFileSync(join(dir, "README.md"), "x\n");
  execFileSync("git", ["add", "-A"], { cwd: dir });
  execFileSync("git", ["commit", "-qm", "start"], { cwd: dir });
  return execFileSync("git", ["rev-parse", "HEAD"], { cwd: dir, encoding: "utf8" }).trim();
}

test("empty home is false for every feature predicate", () => {
  const snap = snapshotHome(home("empty"), { projectSeeds: { greeter: "abc" } });
  for (const until of [
    "registered",
    "dispatched",
    "reported",
    "promoted",
    "relocked",
    "landed",
    "cleaned",
    "kind:scout",
    "status-verb:done",
    "watcher-armed",
  ]) {
    const expected = until === "cleaned";
    assert.equal(evaluateUntil(snap, until), expected, until);
  }
});

test("registered is true only with the registry row and a git clone", () => {
  const h = home("reg");
  writeFileSync(join(h, "data", "projects.md"), "- other [local-only] - x\n");
  let snap = snapshotHome(h, {});
  assert.equal(evaluateUntil(snap, "registered"), false);
  writeFileSync(join(h, "data", "projects.md"), "- greeter [local-only] - x\n");
  snap = snapshotHome(h, {});
  assert.equal(evaluateUntil(snap, "registered"), false);
  gitInit(join(h, "projects", "greeter"));
  snap = snapshotHome(h, {});
  assert.equal(evaluateUntil(snap, "registered"), true);
  assert.equal(evaluateUntil(snap, "registered:other"), false);
});

test("dispatched, kind, status-verb, reported, promoted are literal", () => {
  const h = home("meta");
  writeFileSync(join(h, "state", "abc.meta"), "kind=scout\n");
  writeFileSync(join(h, "state", "abc.status"), "working: go\n");
  let snap = snapshotHome(h, {});
  assert.equal(evaluateUntil(snap, "dispatched"), true);
  assert.equal(evaluateUntil(snap, "meta-count:1"), true);
  assert.equal(evaluateUntil(snap, "meta-count:2"), false);
  assert.equal(evaluateUntil(snap, "kind:scout"), true);
  assert.equal(evaluateUntil(snap, "kind:ship"), false);
  assert.equal(evaluateUntil(snap, "status-verb:working"), true);
  assert.equal(evaluateUntil(snap, "status-verb:done"), false);
  assert.equal(evaluateUntil(snap, "reported"), false);
  mkdirSync(join(h, "data", "abc"), { recursive: true });
  writeFileSync(join(h, "data", "abc", "report.md"), "greet.sh should say hello\n");
  snap = snapshotHome(h, {});
  assert.equal(evaluateUntil(snap, "reported"), true);
  assert.equal(evaluateUntil(snap, "report-exists"), true);
  writeFileSync(join(h, "state", "abc.meta"), "kind=ship\n");
  writeFileSync(join(h, "data", "abc", "ship-instructions.md"), "ship it\n");
  snap = snapshotHome(h, {});
  assert.equal(evaluateUntil(snap, "promoted"), true);
  assert.equal(evaluateUntil(snap, "kind:ship"), true);
});

test("relocked is true only when lock bytes change", () => {
  const h = home("lock");
  writeFileSync(join(h, "state", ".lock"), "old\n");
  let snap = snapshotHome(h, { lockAtReady: "old\n", lockBeforeRelaunch: "old\n" });
  assert.equal(evaluateUntil(snap, "relocked"), false);
  writeFileSync(join(h, "state", ".lock"), "new\n");
  snap = snapshotHome(h, { lockAtReady: "old\n", lockBeforeRelaunch: "old\n" });
  assert.equal(evaluateUntil(snap, "relocked"), true);
});

test("landed and git-ahead compare main to the seed sha", () => {
  const h = home("git");
  const repo = join(h, "projects", "greeter");
  const seed = gitInit(repo);
  let snap = snapshotHome(h, { projectSeeds: { greeter: seed } });
  assert.equal(evaluateUntil(snap, "landed"), false);
  assert.equal(evaluateUntil(snap, "git-ahead:greeter:1"), false);
  writeFileSync(join(repo, "greet.sh"), "echo hi\n");
  execFileSync("git", ["add", "-A"], { cwd: repo });
  execFileSync("git", ["commit", "-qm", "land"], { cwd: repo });
  snap = snapshotHome(h, { projectSeeds: { greeter: seed } });
  assert.equal(evaluateUntil(snap, "landed"), true);
  assert.equal(evaluateUntil(snap, "git-ahead:greeter:1"), true);
});

test("cleaned is true iff no task meta remains", () => {
  const h = home("clean");
  writeFileSync(join(h, "state", "z.meta"), "kind=ship\n");
  let snap = snapshotHome(h, {});
  assert.equal(evaluateUntil(snap, "cleaned"), false);
  rmSync(join(h, "state", "z.meta"));
  snap = snapshotHome(h, {});
  assert.equal(evaluateUntil(snap, "cleaned"), true);
  assert.equal(evaluateUntil(snap, "no-meta"), true);
  assert.equal(evaluateUntil(snap, "home.clean"), true);
});
