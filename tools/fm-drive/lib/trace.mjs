import { lstatSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join, basename } from 'node:path';
import { parseUntil, snapshotHome, evaluateUntil, STARTUP_ONLY, TIMING_ONLY, RESERVED_UNTIL, REMOTE_ATOMS } from './predicates.mjs';

export class TraceError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TraceError';
    this.exitCode = 2;
  }
}

export const RELAUNCH = '$relaunch';
export const INTERPOLATIONS = ['projectOrigin', 'home', 'remoteOrigin'];

const fold = (text) => text.normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-');
const holds = (folded, needle) => `-${folded}-`.includes(`-${needle}-`);

const withoutDotDot = (text) => {
  let out = text.normalize('NFKC').replace(/\\/g, '/').replace(/\/\.(?=\/)/g, '');
  for (let prev; prev !== out;) {
    prev = out;
    out = out.replace(/(?<![^/\s])(?!\.\.?\/)[^/\s]+\/+\.\.(?![\p{L}\p{N}.])/u, '');
  }
  return out;
};

function rootSkills(root) {
  const dirs = new Map();
  for (const dir of ['.agents/skills', '.claude/skills', 'skills']) {
    let names;
    try {
      if (lstatSync(join(root, dir)).isSymbolicLink()) continue;
      names = readdirSync(join(root, dir));
    } catch { continue; }
    for (const name of names) {
      if (statSync(join(root, dir, name), { throwIfNoEntry: false })?.isDirectory()) dirs.set(name, [...(dirs.get(name) ?? []), dir]);
    }
  }
  return [...dirs].map(([name, found]) => ({ name, dirs: found }));
}

function agentOnlySkills(root) {
  return rootSkills(root).filter(({ name, dirs: [dir] }) => {
    let text;
    try { text = readFileSync(join(root, dir, name, 'SKILL.md'), 'utf8'); } catch { return false; }
    const front = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
    return Boolean(front && /^user-invocable:\s*false\s*$/m.test(front[1]));
  }).map(({ name }) => name);
}

function binScripts(root) {
  const bin = join(root, 'bin');
  let entries;
  try { entries = readdirSync(bin, { recursive: true }); } catch { return []; }
  return entries.filter((rel) => statSync(join(bin, rel)).isFile()).flatMap((rel) => {
    const path = `bin/${rel.replace(/\\/g, '/')}`;
    const stem = path.replace(/\.[^./]+$/, '');
    const needles = [{ needle: fold(stem), what: `the script ${path}` }];
    if (stem !== path) needles.push({ needle: fold(basename(path)), what: `the script ${path}` });
    return needles;
  });
}

function skillPaths(root) {
  return rootSkills(root).map(({ name, dirs }) => ({
    needle: `skills-${fold(name)}`,
    what: `the skill file ${dirs.map((dir) => `${dir}/${name}/SKILL.md`).join(' or ')}`,
  }));
}

function steeringIn(say, root) {
  if (!root) return null;
  const folded = fold(withoutDotDot(say));
  const path = [...binScripts(root), ...skillPaths(root)].find(({ needle }) => holds(folded, needle));
  if (path) return path.what;
  const lowered = say.normalize('NFKC').toLowerCase();
  const skill = agentOnlySkills(root).find((name) => {
    const words = fold(name);
    const sigil = new RegExp(`(?:^|[^\\p{L}\\p{N}])[/$]${words.split('-').join('[^\\p{L}\\p{N}]+')}(?![\\p{L}\\p{N}])`, 'u');
    return sigil.test(lowered) || holds(folded, `the-${words}-skill`);
  });
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

export function validateTrace(raw, { root } = {}) {
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
    const steer = steeringIn(step.say, root);
    if (steer) {
      throw new TraceError(`${at}.say invokes ${steer}; that steers the primary with internals, so the run would prove obedience rather than the product`);
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
    if (!(Number.isFinite(step.budgetSec) && step.budgetSec > 0)) {
      throw new TraceError(`${at}.budgetSec must be a positive number of seconds`);
    }
    return { say: step.say, until, parsed, budgetSec: step.budgetSec };
  });
  const featureAtoms = steps.flatMap((s) => s.parsed.atoms).filter((a) => !STARTUP_ONLY.includes(a.name));
  if (featureAtoms.length === 0) {
    throw new TraceError('trace proves only startup (lock.held and friends); every trace needs at least one feature predicate');
  }
  if (steps.some((s) => s.parsed.atoms.some((a) => a.name === 'lock.rotated')) && !steps.some((s) => s.say === RELAUNCH)) {
    throw new TraceError(`lock.rotated needs a ${RELAUNCH} step before it; nothing rotates the lock otherwise`);
  }
  refuseMisplacedSinceAtoms(steps, { project });
  const proves = validateProves(raw.proves, steps.length);
  return { feature: raw.feature, ...(project ? { project } : {}), steps, ...(proves ? { proves } : {}) };
}

function refuseMisplacedSinceAtoms(steps, { project }) {
  const seeded = steps.some((s) => s.say.includes('{{projectOrigin}}')) ? (project || 'greeter') : null;
  const remote = steps.some((s) => s.say.includes('{{remoteOrigin}}'));
  const firstTyped = steps.findIndex((s) => s.say !== '' && s.say !== RELAUNCH);
  let governing = -1;
  const earlier = new Set();
  for (const [i, step] of steps.entries()) {
    if (step.say !== '') governing = i;
    const names = step.parsed.atoms.map((a) => a.name);
    if (names.includes('turn.ended')) {
      const at = `steps[${i}].until`;
      if (governing === -1 || governing === firstTyped || steps[governing].say === RELAUNCH) {
        throw new TraceError(`${at}: turn.ended needs a typed captain say before it; the primary's own startup turn would satisfy it`);
      }
      if (names.every((n) => TIMING_ONLY.includes(n) || STARTUP_ONLY.includes(n))) {
        throw new TraceError(`${at}: turn.ended only times a claim; pair it with a home record`);
      }
      const fresh = step.parsed.atoms.find((a) => !TIMING_ONLY.includes(a.name) && !earlier.has(a.raw));
      if (fresh) throw new TraceError(`${at}: ${fresh.raw} must hold in an earlier step, so turn.ended keeps something this run made true`);
    }
    for (const a of step.parsed.atoms) earlier.add(a.raw);
    for (const atom of step.parsed.atoms) {
      if (REMOTE_ATOMS.includes(atom.name) && !remote) {
        throw new TraceError(`steps[${i}].until: ${atom.name} needs a say that names {{remoteOrigin}}; the driver baselines only the remote it provisioned`);
      }
      if (atom.name === 'git.ahead' && atom.args.name !== seeded) {
        throw new TraceError(`steps[${i}].until: git.ahead:${atom.args.name} needs the project the driver seeds through {{projectOrigin}}; an unseeded clone counts any main as ahead`);
      }
    }
  }
}

// proves maps each inventory row id the trace proves to its last proving
// step, 1-based: the row is proven when every step through that one held.
function validateProves(raw, stepCount) {
  if (raw === undefined) return null;
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new TraceError('trace.proves must map each inventory row id to its last proving step');
  }
  for (const [id, step] of Object.entries(raw)) {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id)) throw new TraceError(`trace.proves: ${JSON.stringify(id)} is not an inventory row id`);
    if (!Number.isInteger(step) || step < 1 || step > stepCount) {
      throw new TraceError(`trace.proves.${id} must be a step number from 1 to ${stepCount}`);
    }
  }
  return { ...raw };
}

export function refuseVacuousOnFreshHome(trace, home) {
  const snap = snapshotHome(home);
  snap.herdr = { tabLabels: [], panes: {} };
  const ctx = { since: null, seeds: {}, seenTaskIds: new Set() };
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
