// Trace loading and refusal. Everything here runs before any herdr call.
//
// A trace is { feature, project?, steps: [{ say, until, budgetSec? }] }. `say`
// is captain text typed into the primary, "" to wait without typing, or the
// reserved verb "$relaunch". `until` is a closed catalog expression
// (lib/predicates.mjs). `project` names the throwaway project seeded when a
// say mentions {{projectOrigin}} (default greeter).
// Refusal is a thrown TraceError; drive.mjs maps it to exit 2.

import { readFileSync } from 'node:fs';
import { parseUntil, STARTUP_ONLY, RESERVED_UNTIL } from './predicates.mjs';

export class TraceError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TraceError';
    this.exitCode = 2;
  }
}

export const RELAUNCH = '$relaunch';
export const INTERPOLATIONS = ['projectOrigin', 'home'];

export function loadTrace(filePath) {
  let text;
  try {
    text = readFileSync(filePath, 'utf8');
  } catch (err) {
    throw new TraceError(`cannot read trace ${filePath}: ${err.message}`);
  }
  let raw;
  try {
    raw = JSON.parse(text);
  } catch (err) {
    throw new TraceError(`trace ${filePath} is not JSON: ${err.message}`);
  }
  return validateTrace(raw);
}

export function validateTrace(raw) {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new TraceError('trace must be a JSON object');
  }
  if (typeof raw.feature !== 'string' || raw.feature.trim() === '') {
    throw new TraceError('trace.feature must be a non-empty string');
  }
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(raw.feature)) {
    throw new TraceError('trace.feature must be a plain token (letters, digits, dot, dash, underscore)');
  }
  if (!Array.isArray(raw.steps) || raw.steps.length === 0) {
    throw new TraceError('trace.steps must be a non-empty array');
  }
  let project;
  if (raw.project !== undefined) {
    if (typeof raw.project !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(raw.project)) {
      throw new TraceError('trace.project must be a plain project name token');
    }
    project = raw.project;
  }
  const steps = raw.steps.map((step, i) => {
    const at = `steps[${i}]`;
    if (step === null || typeof step !== 'object' || Array.isArray(step)) {
      throw new TraceError(`${at} must be an object`);
    }
    if (typeof step.say !== 'string') throw new TraceError(`${at}.say must be a string`);
    if (typeof step.until !== 'string') throw new TraceError(`${at}.until must be a string`);
    if (step.say.startsWith('$') && step.say !== RELAUNCH) {
      throw new TraceError(`${at}.say: unknown reserved verb ${JSON.stringify(step.say)}; only ${RELAUNCH} is defined`);
    }
    for (const m of step.say.matchAll(/\{\{\s*([^}]*?)\s*\}\}/g)) {
      if (!INTERPOLATIONS.includes(m[1])) {
        throw new TraceError(`${at}.say: unknown interpolation {{${m[1]}}}; known: ${INTERPOLATIONS.map((k) => `{{${k}}}`).join(', ')}`);
      }
    }
    const until = step.until.trim();
    if (RESERVED_UNTIL.includes(until)) {
      throw new TraceError(`${at}.until ${JSON.stringify(until)} only proves the harness started; it is not a firstmate claim`);
    }
    let parsed;
    try {
      parsed = parseUntil(until);
    } catch (err) {
      throw new TraceError(`${at}.until: ${err.message}`);
    }
    let budgetSec;
    if (step.budgetSec !== undefined) {
      if (typeof step.budgetSec !== 'number' || !Number.isFinite(step.budgetSec) || step.budgetSec <= 0) {
        throw new TraceError(`${at}.budgetSec must be a positive number of seconds`);
      }
      budgetSec = step.budgetSec;
    }
    return { say: step.say, until, parsed, budgetSec };
  });
  const featureAtoms = steps.flatMap((s) => s.parsed.atoms).filter((a) => !STARTUP_ONLY.includes(a.name));
  if (featureAtoms.length === 0) {
    throw new TraceError('trace proves only startup (lock.held and friends); every trace needs at least one feature predicate');
  }
  if (steps.some((s) => s.parsed.atoms.some((a) => a.name === 'lock.rotated')) && !steps.some((s) => s.say === RELAUNCH)) {
    throw new TraceError(`lock.rotated needs a ${RELAUNCH} step before it; nothing rotates the lock otherwise`);
  }
  return { feature: raw.feature, ...(project ? { project } : {}), steps };
}

// Replace {{name}} tokens in every say. Unknown names were refused at load.
export function interpolate(trace, vars) {
  return {
    ...trace,
    steps: trace.steps.map((s) => ({
      ...s,
      say: s.say.replace(/\{\{\s*([^}]*?)\s*\}\}/g, (_, k) => {
        if (!(k in vars)) throw new TraceError(`no value for {{${k}}}`);
        return vars[k];
      }),
    })),
  };
}
