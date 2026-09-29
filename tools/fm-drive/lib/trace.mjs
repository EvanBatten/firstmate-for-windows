import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { parseUntil, snapshotHome, evaluateUntil, STARTUP_ONLY, RESERVED_UNTIL } from './predicates.mjs';

export class TraceError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TraceError';
    this.exitCode = 2;
  }
}

export const RELAUNCH = '$relaunch';
export const INTERPOLATIONS = ['projectOrigin', 'home'];

const NORMALIZED_STEERING = [
  { pattern: /\bbin\//, what: 'a bin/ path' },
  { pattern: /\bstate\//, what: 'a state/ path' },
  { pattern: /\bfm-[a-z0-9]/, what: 'a firstmate script' },
  { pattern: /\btasks-?axi\b/, what: 'tasks-axi' },
  { pattern: /\bsession-?start/, what: 'session start' },
];

export function normalizeSay(say) {
  return say.replace(/([a-z0-9])([A-Z])/g, '$1-$2').toLowerCase().replace(/\\/g, '/').replace(/[_\s]+/g, '-');
}

export function agentOnlySkills(root) {
  const dir = join(root, '.agents', 'skills');
  let names;
  try { names = readdirSync(dir); } catch { return []; }
  return names.filter((name) => {
    let text;
    try { text = readFileSync(join(dir, name, 'SKILL.md'), 'utf8'); } catch { return false; }
    const front = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
    return Boolean(front && /^user-invocable:\s*false\s*$/m.test(front[1]));
  }).sort();
}

function steeringIn(say, agentSkills) {
  const said = normalizeSay(say);
  const hit = NORMALIZED_STEERING.find(({ pattern }) => pattern.test(said));
  if (hit) return hit.what;
  const skill = agentSkills.find((name) => new RegExp(`\\b${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`).test(said));
  return skill ? `the agent-only skill ${skill}` : null;
}

export function loadTrace(filePath, options) {
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
  return validateTrace(raw, options);
}

export function validateTrace(raw, { agentSkills = [] } = {}) {
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
    const steer = steeringIn(step.say, agentSkills);
    if (steer) {
      throw new TraceError(`${at}.say names ${steer}; that steers the primary with internals, so the run would prove obedience rather than the product`);
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

export function refuseVacuousOnFreshHome(trace, home) {
  const snap = snapshotHome(home);
  snap.herdr = { tabLabels: [], panes: {} };
  const ctx = { lockBaseline: undefined, seeds: {}, seenTaskIds: new Set() };
  if (trace.steps.every((s) => evaluateUntil(s.parsed, snap, ctx).ok)) {
    throw new TraceError(`every until already holds on a fresh clone of the home (${trace.steps.map((s) => s.until).join('; ')}), so the trace would pass with firstmate doing nothing`);
  }
}

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
