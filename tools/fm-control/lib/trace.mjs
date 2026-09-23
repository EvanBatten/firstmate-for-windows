import { readFileSync } from "node:fs";

/** Tokens that only prove harness startup, never a firstmate feature. */
export const STARTUP_ONLY = new Set([
  "pong",
  "bypass permissions on",
  "lock",
  "lock.held",
  "lock-held",
  "held-lock",
]);

/**
 * Closed catalog. Unknown strings refuse the trace.
 * Optional `:args` are part of the token grammar, not free text.
 */
export const CATALOG = new Set([
  "registered",
  "dispatched",
  "meta-count",
  "kind",
  "status-verb",
  "reported",
  "report-exists",
  "promoted",
  "relocked",
  "lock-rotated",
  "landed",
  "git-ahead",
  "cleaned",
  "no-meta",
  "home.clean",
  "watcher-armed",
]);

const KIND = new Set(["scout", "ship"]);
const STATUS_VERB = new Set(["done", "blocked", "working", "paused"]);
const NAME = /^[A-Za-z0-9._-]+$/;
const INTERP = /\{\{([A-Za-z0-9_]+)\}\}/g;

export function parseUntil(until) {
  if (typeof until !== "string" || until.trim() === "") {
    return { error: "until must be a non-empty string" };
  }
  const raw = until.trim();
  if (STARTUP_ONLY.has(raw)) {
    return { error: `startup-only until is not a feature predicate: ${raw}` };
  }
  const [head, ...rest] = raw.split(":");
  if (!CATALOG.has(head)) {
    return { error: `unknown until token: ${raw}` };
  }
  if (head === "registered" || head === "landed") {
    if (rest.length > 1) return { error: `bad ${head} args: ${raw}` };
    if (rest[0] && !NAME.test(rest[0])) return { error: `bad project name: ${raw}` };
    return { token: head, name: rest[0] || "greeter" };
  }
  if (head === "meta-count") {
    if (rest.length !== 1 || !/^\d+$/.test(rest[0])) {
      return { error: `meta-count needs a non-negative integer: ${raw}` };
    }
    return { token: head, n: Number(rest[0]) };
  }
  if (head === "kind") {
    if (rest.length !== 1 || !KIND.has(rest[0])) {
      return { error: `kind must be scout or ship: ${raw}` };
    }
    return { token: head, kind: rest[0] };
  }
  if (head === "status-verb") {
    if (rest.length !== 1 || !STATUS_VERB.has(rest[0])) {
      return { error: `status-verb must be done|blocked|working|paused: ${raw}` };
    }
    return { token: head, verb: rest[0] };
  }
  if (head === "reported") {
    if (rest.length > 1) return { error: `bad reported args: ${raw}` };
    return { token: head, needle: rest[0] || "greet" };
  }
  if (head === "git-ahead") {
    const name = rest[0] || "greeter";
    const n = rest[1] === undefined ? 1 : rest[1];
    if (!NAME.test(name) || !/^\d+$/.test(String(n))) {
      return { error: `git-ahead needs name and non-negative integer: ${raw}` };
    }
    return { token: head, name, n: Number(n) };
  }
  if (rest.length) return { error: `${head} takes no arguments: ${raw}` };
  return { token: head };
}

export function validateTrace(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { error: "trace must be an object" };
  }
  if (typeof raw.feature !== "string" || raw.feature.trim() === "") {
    return { error: "feature must be a non-empty string" };
  }
  if (!Array.isArray(raw.steps) || raw.steps.length === 0) {
    return { error: "steps must be a non-empty array" };
  }
  const steps = [];
  const untils = [];
  for (const [i, step] of raw.steps.entries()) {
    if (!step || typeof step !== "object" || Array.isArray(step)) {
      return { error: `step ${i} must be an object` };
    }
    if (typeof step.say !== "string") {
      return { error: `step ${i} say must be a string` };
    }
    if (typeof step.until !== "string") {
      return { error: `step ${i} until must be a string` };
    }
    if (step.budgetSec !== undefined) {
      if (typeof step.budgetSec !== "number" || !Number.isFinite(step.budgetSec) || step.budgetSec <= 0) {
        return { error: `step ${i} budgetSec must be a positive number` };
      }
    }
    if (step.say.startsWith("$") && step.say !== "$relaunch" && step.say !== "$exit") {
      return { error: `step ${i} unknown reserved say: ${step.say}` };
    }
    const parsed = parseUntil(step.until);
    if (parsed.error) return { error: `step ${i}: ${parsed.error}` };
    const unknownInterp = [...step.say.matchAll(INTERP)]
      .map((m) => m[1])
      .filter((name) => name !== "projectOrigin" && name !== "home");
    if (unknownInterp.length) {
      return { error: `step ${i} unknown interpolation: {{${unknownInterp[0]}}}` };
    }
    untils.push(step.until.trim());
    steps.push({
      say: step.say,
      until: step.until.trim(),
      budgetSec: step.budgetSec,
      parsed,
    });
  }
  if (untils.every((u) => STARTUP_ONLY.has(u))) {
    return { error: "startup-only trace: predicates only prove harness ready" };
  }
  return {
    trace: {
      feature: raw.feature.trim(),
      steps,
    },
  };
}

export function loadTrace(filePath) {
  let text;
  try {
    text = readFileSync(filePath, "utf8");
  } catch {
    return { error: `cannot read trace: ${filePath}` };
  }
  let raw;
  try {
    raw = JSON.parse(text);
  } catch {
    return { error: "trace is not valid JSON" };
  }
  return validateTrace(raw);
}

export function interpolateTrace(trace, vars) {
  const replace = (s) =>
    s.replace(INTERP, (_, name) => (name in vars ? String(vars[name]) : `{{${name}}}`));
  return {
    ...trace,
    steps: trace.steps.map((step) => ({
      ...step,
      say: replace(step.say),
    })),
  };
}

export function isReservedSay(say) {
  return say === "$relaunch" || say === "$exit";
}
