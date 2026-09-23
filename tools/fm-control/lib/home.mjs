import {
  lstatSync,
  readFileSync,
  readlinkSync,
  readdirSync,
  statSync,
  watch,
} from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { inflateSync } from "node:zlib";

function readText(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

export function lockIdentity(home) {
  const path = join(home, "state", ".lock");
  try {
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) return `link:${readlinkSync(path)}`;
    if (stat.isFile()) return `file:${readFileSync(path, "utf8")}`;
    return `other:${stat.ino}:${stat.mtimeMs}`;
  } catch {
    return null;
  }
}

function parseKeyValues(text) {
  const result = {};
  for (const line of (text || "").split(/\r?\n/)) {
    const split = line.indexOf("=");
    if (split > 0) result[line.slice(0, split)] = line.slice(split + 1);
  }
  return result;
}

function gitDirectory(project) {
  const dotGit = join(project, ".git");
  try {
    if (statSync(dotGit).isDirectory()) return dotGit;
  } catch {
    return null;
  }
  const marker = readText(dotGit);
  const match = marker && /^gitdir:\s*(.+)\s*$/m.exec(marker);
  if (!match) return null;
  return isAbsolute(match[1]) ? match[1] : resolve(project, match[1]);
}

function readRef(gitDir, ref) {
  const loose = readText(join(gitDir, ...ref.split("/")));
  if (loose && /^[0-9a-f]{40}\s*$/i.test(loose)) return loose.trim();
  const packed = readText(join(gitDir, "packed-refs"));
  if (!packed) return null;
  for (const line of packed.split(/\r?\n/)) {
    const match = /^([0-9a-f]{40}) (.+)$/i.exec(line);
    if (match && match[2] === ref) return match[1];
  }
  return null;
}

function readLooseObject(gitDir, sha) {
  try {
    const compressed = readFileSync(join(gitDir, "objects", sha.slice(0, 2), sha.slice(2)));
    const object = inflateSync(compressed);
    const nul = object.indexOf(0);
    return nul >= 0 ? object.subarray(nul + 1).toString("utf8") : null;
  } catch {
    return null;
  }
}

function commitsAhead(gitDir, head, seed) {
  if (!head || !seed || head === seed) return 0;
  let count = 0;
  let cursor = head;
  const seen = new Set();
  while (cursor && cursor !== seed && count < 1000 && !seen.has(cursor)) {
    seen.add(cursor);
    count += 1;
    const commit = readLooseObject(gitDir, cursor);
    if (!commit) return count;
    const parent = /^parent ([0-9a-f]{40})$/m.exec(commit);
    cursor = parent ? parent[1] : null;
  }
  return cursor === seed ? count : 0;
}

function listFiles(path, suffix) {
  try {
    return readdirSync(path, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith(suffix))
      .map((entry) => entry.name);
  } catch {
    return [];
  }
}

function reportExists(home) {
  const data = join(home, "data");
  try {
    for (const entry of readdirSync(data, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const report = readText(join(data, entry.name, "report.md"));
      if (report && report.trim()) return true;
    }
  } catch {
    return false;
  }
  return false;
}

function pendingInboxCount(home, taskIds) {
  let count = 0;
  for (const id of taskIds) {
    count += listFiles(join(home, "state", `${id}.inbox`), ".msg").length;
  }
  return count;
}

export function snapshotHome(home, context = {}) {
  const state = join(home, "state");
  const taskIds = listFiles(state, ".meta").map((name) => name.slice(0, -5)).sort();
  const meta = {};
  const status = {};
  for (const id of taskIds) {
    meta[id] = parseKeyValues(readText(join(state, `${id}.meta`)));
    status[id] = readText(join(state, `${id}.status`)) || "";
  }
  for (const name of listFiles(state, ".status")) {
    const id = name.slice(0, -7);
    if (!(id in status)) status[id] = readText(join(state, name)) || "";
  }

  const projects = {};
  const names = new Set(Object.keys(context.projectSeeds || {}));
  const projectsRoot = join(home, "projects");
  try {
    for (const entry of readdirSync(projectsRoot, { withFileTypes: true })) {
      if (entry.isDirectory()) names.add(entry.name);
    }
  } catch {}
  for (const name of names) {
    const project = join(projectsRoot, name);
    const gitDir = gitDirectory(project);
    const head = gitDir ? readRef(gitDir, "refs/heads/main") : null;
    projects[name] = {
      exists: Boolean(gitDir),
      head,
      ahead: gitDir
        ? commitsAhead(gitDir, head, (context.projectSeeds || {})[name])
        : 0,
    };
  }

  const wake = readText(join(state, ".wake-queue"));
  const wakeEmpty = !wake || !wake.split(/\r?\n/).some((line) => line.trim());
  const pendingInbox = pendingInboxCount(home, taskIds);
  return {
    home,
    projectsMd: readText(join(home, "data", "projects.md")) || "",
    projects,
    taskIds,
    meta,
    status,
    reportExists: reportExists(home),
    lock: lockIdentity(home),
    wakeEmpty,
    pendingInbox,
  };
}

function registryHas(projectsMd, name) {
  return projectsMd.split(/\r?\n/).some((line) => line.startsWith(`- ${name} `));
}

export function evaluatePredicate(snapshot, parsed, context = {}) {
  switch (parsed.kind) {
    case "project-registered": {
      const name = parsed.args[0];
      return registryHas(snapshot.projectsMd, name) &&
        snapshot.projects[name]?.exists === true;
    }
    case "task-count":
      return snapshot.taskIds.length >= parsed.args[0];
    case "task-kind":
      return Object.values(snapshot.meta).some((record) => record.kind === parsed.args[0]);
    case "status-verb": {
      const prefix = `${parsed.args[0]}:`;
      return Object.values(snapshot.status).some((text) =>
        text.split(/\r?\n/).some((line) => line.startsWith(prefix)));
    }
    case "report-exists":
      return snapshot.reportExists === true;
    case "lock-held":
      return snapshot.lock !== null;
    case "lock-rotated":
      return snapshot.lock !== null && context.lockBefore !== null &&
        snapshot.lock !== context.lockBefore;
    case "git-ahead":
      return (snapshot.projects[parsed.args[0]]?.ahead || 0) >= parsed.args[1];
    case "clean-home":
      return snapshot.taskIds.length === 0 && snapshot.wakeEmpty === true &&
        snapshot.pendingInbox === 0;
    case "wake-empty":
      return snapshot.wakeEmpty === true;
    default:
      return false;
  }
}

export function waitForPredicate({
  home,
  parsed,
  context,
  budgetMs,
  onSnapshot,
  failureEmitter,
}) {
  return new Promise((resolveWait) => {
    let settled = false;
    let debounce = null;
    let watcher = null;

    const finish = (ok, reason, snapshot) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (debounce) clearTimeout(debounce);
      if (watcher) watcher.close();
      failureEmitter?.off("failure", fail);
      resolveWait({ ok, reason, snapshot });
    };
    const evaluate = () => {
      let snapshot;
      try {
        snapshot = snapshotHome(home, context);
        onSnapshot?.(snapshot);
        if (evaluatePredicate(snapshot, parsed, context)) {
          finish(true, null, snapshot);
        }
      } catch (error) {
        finish(false, `home snapshot failed: ${error.message}`, snapshot);
      }
    };
    const changed = () => {
      if (debounce) clearTimeout(debounce);
      debounce = setTimeout(evaluate, 15);
    };
    const fail = (reason) => finish(false, reason, null);
    const timer = setTimeout(() => finish(false, "deadline exceeded", null), budgetMs);

    failureEmitter?.once("failure", fail);
    try {
      watcher = watch(home, { recursive: true }, changed);
      watcher.on("error", (error) => finish(false, `home watch failed: ${error.message}`, null));
    } catch (error) {
      finish(false, `home watch failed: ${error.message}`, null);
      return;
    }
    evaluate();
  });
}

export function watcherPid(home) {
  const value = readText(join(home, "state", ".watch.lock", "pid"));
  return value && /^[0-9]+$/.test(value.trim()) ? Number(value.trim()) : null;
}
