import { readFileSync } from "node:fs";

const FEATURE = /^[A-Za-z0-9._-]+$/;
const NAME = /^[A-Za-z0-9._-]+$/;
const STATUS_VERBS = new Set([
  "working",
  "blocked",
  "paused",
  "done",
  "needs-decision",
  "resolved",
  "note",
]);
const RESERVED_SAYS = new Set(["$relaunch"]);
const INTERPOLATIONS = new Set(["projectOrigin", "home"]);

export class TraceError extends Error {}

function integer(value, label) {
  if (!/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new TraceError(`${label} must be a non-negative integer`);
  }
  return Number(value);
}

export function parseUntil(until) {
  if (until === "lock-held" || until === "lock-rotated" ||
      until === "report-exists" || until === "clean-home" ||
      until === "wake-empty") {
    return { kind: until, args: [] };
  }

  let match = /^project-registered:([^:]+)$/.exec(until);
  if (match && NAME.test(match[1])) {
    return { kind: "project-registered", args: [match[1]] };
  }

  match = /^task-count:([^:]+)$/.exec(until);
  if (match) {
    return { kind: "task-count", args: [integer(match[1], "task-count")] };
  }

  match = /^task-kind:([^:]+)$/.exec(until);
  if (match && (match[1] === "scout" || match[1] === "ship")) {
    return { kind: "task-kind", args: [match[1]] };
  }

  match = /^status-verb:([^:]+)$/.exec(until);
  if (match && STATUS_VERBS.has(match[1])) {
    return { kind: "status-verb", args: [match[1]] };
  }

  match = /^git-ahead:([^:]+):([^:]+)$/.exec(until);
  if (match && NAME.test(match[1])) {
    return {
      kind: "git-ahead",
      args: [match[1], integer(match[2], "git-ahead count")],
    };
  }

  throw new TraceError(`unknown until predicate: ${until}`);
}

function validateStep(step, index) {
  if (!step || typeof step !== "object" || Array.isArray(step)) {
    throw new TraceError(`step ${index + 1} must be an object`);
  }
  if (typeof step.say !== "string" || typeof step.until !== "string") {
    throw new TraceError(`step ${index + 1} requires string say and until`);
  }
  if (step.say.startsWith("$") && !RESERVED_SAYS.has(step.say)) {
    throw new TraceError(`step ${index + 1} has unknown lifecycle say`);
  }
  for (const match of step.say.matchAll(/\{\{([^{}]+)\}\}/g)) {
    if (!INTERPOLATIONS.has(match[1])) {
      throw new TraceError(`step ${index + 1} has unknown interpolation`);
    }
  }
  const parsedUntil = parseUntil(step.until);
  let budgetSec = 1200;
  if (step.budgetSec !== undefined) {
    if (!Number.isInteger(step.budgetSec) || step.budgetSec <= 0) {
      throw new TraceError(`step ${index + 1} budgetSec must be a positive integer`);
    }
    budgetSec = step.budgetSec;
  }
  return { say: step.say, until: step.until, budgetSec, parsedUntil };
}

export function validateTrace(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TraceError("trace must be an object");
  }
  if (typeof value.feature !== "string" || !FEATURE.test(value.feature)) {
    throw new TraceError("feature must be a non-empty filename-safe token");
  }
  if (!Array.isArray(value.steps) || value.steps.length === 0) {
    throw new TraceError("steps must be a non-empty array");
  }
  const steps = value.steps.map(validateStep);
  if (steps.every((step) => step.parsedUntil.kind === "lock-held")) {
    throw new TraceError("trace predicates prove startup only");
  }
  return { feature: value.feature, steps };
}

export function loadTrace(filePath) {
  let value;
  try {
    value = JSON.parse(readFileSync(filePath, "utf8"));
  } catch (error) {
    throw new TraceError(`could not read trace: ${error.message}`);
  }
  return validateTrace(value);
}

export function interpolateTrace(trace, variables) {
  return {
    feature: trace.feature,
    steps: trace.steps.map((step) => ({
      ...step,
      say: step.say.replaceAll("{{projectOrigin}}", variables.projectOrigin)
        .replaceAll("{{home}}", variables.home),
    })),
  };
}
