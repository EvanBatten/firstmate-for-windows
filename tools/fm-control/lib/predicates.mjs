import { parseUntil } from "./trace.mjs";

function registered(snap, name) {
  const row = snap.projectsMd && new RegExp(`^- ${name} `, "m").test(snap.projectsMd);
  return Boolean(row && snap.projectGit[name]?.exists);
}

function gitAhead(snap, name, n) {
  const sha = snap.projectGit[name]?.mainSha;
  const seed = snap.projectSeeds[name];
  if (!sha || !seed) return false;
  if (n <= 0) return true;
  return sha !== seed;
}

function relocked(snap) {
  const prior = snap.lockBeforeRelaunch ?? snap.lockAtReady;
  return Boolean(snap.lockText && prior && snap.lockText !== prior);
}

function cleaned(snap) {
  return snap.taskIds.length === 0;
}

function reported(snap, needle) {
  const re = new RegExp(needle, "i");
  return Object.values(snap.reports).some((text) => text && text.trim() && re.test(text));
}

/**
 * predicate(until) -> (HomeSnapshot) => boolean
 * Pure: no herdr, no spawn, no sleep.
 */
export function predicate(until) {
  const parsed = typeof until === "string" ? parseUntil(until) : until;
  if (parsed.error) {
    return () => false;
  }
  const token = parsed.token;
  return (snap) => {
    switch (token) {
      case "registered":
        return registered(snap, parsed.name);
      case "dispatched":
        return snap.taskIds.length >= 1;
      case "meta-count":
        return snap.taskIds.length >= parsed.n;
      case "kind":
        return Object.values(snap.meta).some((m) => m.kind === parsed.kind);
      case "status-verb":
        return Object.values(snap.status).some((text) =>
          new RegExp(`^${parsed.verb}:`, "m").test(text),
        );
      case "reported":
        return reported(snap, parsed.needle);
      case "report-exists":
        return Object.values(snap.reports).some((text) => text && text.trim());
      case "promoted":
        return (
          Object.values(snap.meta).some((m) => m.kind === "ship") ||
          Object.values(snap.shipInstructions).some((text) => text && text.trim())
        );
      case "relocked":
      case "lock-rotated":
        return relocked(snap);
      case "landed":
        return gitAhead(snap, parsed.name, 1);
      case "git-ahead":
        return gitAhead(snap, parsed.name, parsed.n);
      case "cleaned":
      case "no-meta":
      case "home.clean":
        return cleaned(snap);
      case "watcher-armed":
        return (
          snap.watchLockPidAlive &&
          snap.lastWatcherBeatMs !== null &&
          snap.capturedAtMs - snap.lastWatcherBeatMs < 300_000
        );
      default:
        return false;
    }
  };
}

export function evaluateUntil(snap, until) {
  return predicate(until)(snap);
}
