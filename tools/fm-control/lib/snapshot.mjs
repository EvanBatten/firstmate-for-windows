import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

function readText(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

function parseMeta(text) {
  const out = {};
  if (!text) return out;
  for (const line of text.split(/\r?\n/)) {
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = line.slice(0, eq);
    if (out[key] === undefined) out[key] = line.slice(eq + 1);
  }
  return out;
}

function gitDir(repo) {
  const dot = join(repo, ".git");
  if (!existsSync(dot)) return null;
  try {
    if (statSync(dot).isDirectory()) return dot;
  } catch {
    return null;
  }
  const text = readText(dot);
  const m = text && text.match(/^gitdir:\s*(.+)\s*$/m);
  return m ? m[1].trim() : null;
}

function readPackedRef(git, name) {
  const packed = readText(join(git, "packed-refs"));
  if (!packed) return null;
  const needle = ` refs/${name}`;
  for (const line of packed.split(/\r?\n/)) {
    if (line.startsWith("#") || line.startsWith("^")) continue;
    if (line.endsWith(needle)) return line.split(" ")[0];
  }
  return null;
}

export function readRefSha(repo, ref = "heads/main") {
  const git = gitDir(repo);
  if (!git) return null;
  const loose = readText(join(git, "refs", ...ref.split("/")));
  if (loose && /^[0-9a-f]{40,64}$/i.test(loose.trim())) return loose.trim();
  return readPackedRef(git, ref);
}

function pidAlive(pid) {
  if (!pid || !/^\d+$/.test(pid)) return false;
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

/**
 * HomeSnapshot is a value. Predicates read only this.
 * Stamps (lockAtReady, lockBeforeRelaunch, projectSeeds) ride on the value
 * so predicate functions stay pure.
 */
export function snapshotHome(home, stamps = {}) {
  const state = join(home, "state");
  const data = join(home, "data");
  const projects = join(home, "projects");
  let metas = [];
  try {
    metas = readdirSync(state).filter((n) => n.endsWith(".meta"));
  } catch {
    metas = [];
  }
  const taskIds = metas.map((n) => n.slice(0, -".meta".length));
  const meta = {};
  const status = {};
  for (const id of taskIds) {
    meta[id] = parseMeta(readText(join(state, `${id}.meta`)));
    status[id] = readText(join(state, `${id}.status`)) || "";
  }
  const reports = {};
  const shipInstructions = {};
  try {
    for (const id of readdirSync(data)) {
      const report = readText(join(data, id, "report.md"));
      if (report !== null) reports[id] = report;
      const ship = readText(join(data, id, "ship-instructions.md"));
      if (ship !== null) shipInstructions[id] = ship;
    }
  } catch {
    /* no data yet */
  }
  const projectGit = {};
  try {
    for (const name of readdirSync(projects)) {
      const repo = join(projects, name);
      projectGit[name] = {
        exists: existsSync(join(repo, ".git")),
        mainSha: readRefSha(repo, "heads/main"),
      };
    }
  } catch {
    /* no projects yet */
  }
  const watchPid = readText(join(state, ".watch.lock", "pid"));
  let lastWatcherBeatMs = null;
  try {
    lastWatcherBeatMs = statSync(join(state, ".last-watcher-beat")).mtimeMs;
  } catch {
    lastWatcherBeatMs = null;
  }
  return {
    home,
    projectsMd: readText(join(data, "projects.md")),
    projectGit,
    taskIds,
    meta,
    status,
    reports,
    shipInstructions,
    lockText: readText(join(state, ".lock")),
    watchLockPid: watchPid ? watchPid.trim() : null,
    watchLockPidAlive: pidAlive(watchPid && watchPid.trim()),
    lastWatcherBeatMs,
    lockAtReady: stamps.lockAtReady ?? null,
    lockBeforeRelaunch: stamps.lockBeforeRelaunch ?? null,
    projectSeeds: stamps.projectSeeds || {},
    capturedAtMs: Date.now(),
  };
}
