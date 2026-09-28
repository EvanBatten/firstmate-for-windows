// The closed `until` catalog and the home snapshot it reads.
//
// An `until` is a conjunction of atoms joined by `&&`. Every atom is a claim
// about the throwaway firstmate home (state/, data/, projects/), never about
// pane text. Two atoms (tabs.clean, worker.alive) additionally need one herdr
// fact, which the wait loop fetches lazily and stores on the snapshot so
// evaluation itself stays a pure function of the snapshot and the run context.
//
// Catalog (arguments after ':'; NAME is [A-Za-z0-9._-]+, N a non-negative integer):
//   projects.registered:NAME    data/projects.md has a "- NAME " row and projects/NAME/.git exists
//   tasks.count>=N              at least N state/*.meta task records
//   backlog.inflight>=N         data/backlog.md lists at least N items under "## In flight"
//                               (fm-spawn's commit point: a record whose item is not In flight is
//                               a spawn still in progress, which its abort cleanup may remove)
//   tasks.kind:scout|ship       some task record carries kind=<value>
//   status.verb:VERB            some state/*.status line starts with "VERB:"
//                               (done, needs-decision, blocked, failed, working, paused, resolved, note)
//   report.exists               some data/<id>/report.md is non-empty
//   report.mentions:NEEDLE      some data/<id>/report.md contains NEEDLE (case-insensitive)
//   inbox.handled               some state/<id>.inbox/handled/ holds an acknowledged steer
//   lock.held                   state/.lock exists and is non-empty (startup-only; never enough alone)
//   lock.rotated                state/.lock differs from the identity captured when the last $relaunch began
//   git.ahead:NAME>=N           projects/NAME main is at least N commits ahead of the seeded base
//   home.clean                  no state/*.meta task record remains
//   tabs.clean                  no herdr tab labelled fm-<id> for a task this run ever recorded is open
//   worker.alive                every recorded task's herdr pane still answers
//   wake.empty                  state/.wake-queue is missing or has no non-blank line
//   beacon.fresh                state/.last-watcher-beat was touched within 300 s
//   file.contains:REL:NEEDLE    <home>/REL exists and contains NEEDLE (REL must stay inside the home)
//
// Reserved, refused: "pong" and "bypass permissions on" prove only that the harness started.

import { readFileSync, readdirSync, existsSync, statSync, lstatSync } from 'node:fs';
import { join, resolve, sep } from 'node:path';

export const RESERVED_UNTIL = ['pong', 'bypass permissions on'];
export const STARTUP_ONLY = ['lock.held'];
export const STATUS_VERBS = ['done', 'needs-decision', 'blocked', 'failed', 'working', 'paused', 'resolved', 'note', 'captain-held'];
export const HERDR_ATOMS = ['tabs.clean', 'worker.alive'];
const NAME = '[A-Za-z0-9._-]+';

const ATOMS = [
  { name: 'projects.registered', re: new RegExp(`^projects\\.registered:(${NAME})$`), args: ['name'] },
  { name: 'tasks.count', re: /^tasks\.count>=(\d+)$/, args: ['n'], int: ['n'] },
  { name: 'backlog.inflight', re: /^backlog\.inflight>=(\d+)$/, args: ['n'], int: ['n'] },
  { name: 'tasks.kind', re: /^tasks\.kind:(scout|ship)$/, args: ['kind'] },
  { name: 'status.verb', re: new RegExp(`^status\\.verb:(${STATUS_VERBS.join('|')})$`), args: ['verb'] },
  { name: 'report.exists', re: /^report\.exists$/, args: [] },
  { name: 'report.mentions', re: /^report\.mentions:(.+)$/, args: ['needle'] },
  { name: 'inbox.handled', re: /^inbox\.handled$/, args: [] },
  { name: 'lock.held', re: /^lock\.held$/, args: [] },
  { name: 'lock.rotated', re: /^lock\.rotated$/, args: [] },
  { name: 'git.ahead', re: new RegExp(`^git\\.ahead:(${NAME})>=(\\d+)$`), args: ['name', 'n'], int: ['n'] },
  { name: 'home.clean', re: /^home\.clean$/, args: [] },
  { name: 'tabs.clean', re: /^tabs\.clean$/, args: [] },
  { name: 'worker.alive', re: /^worker\.alive$/, args: [] },
  { name: 'wake.empty', re: /^wake\.empty$/, args: [] },
  { name: 'beacon.fresh', re: /^beacon\.fresh$/, args: [] },
  { name: 'file.contains', re: /^file\.contains:([^:]+):(.+)$/, args: ['rel', 'needle'] },
];

export const CATALOG = ATOMS.map((a) => a.name);

export function parseAtom(text) {
  const raw = text.trim();
  if (raw === '') throw new Error('empty predicate');
  for (const def of ATOMS) {
    const m = def.re.exec(raw);
    if (!m) continue;
    const args = {};
    def.args.forEach((k, i) => { args[k] = m[i + 1]; });
    for (const k of def.int ?? []) args[k] = Number.parseInt(args[k], 10);
    if (def.name === 'file.contains') {
      const rel = args.rel.replace(/\\/g, '/');
      if (rel.startsWith('/') || /^[A-Za-z]:/.test(rel) || rel.split('/').includes('..')) {
        throw new Error(`file.contains path ${JSON.stringify(args.rel)} must stay inside the home`);
      }
    }
    return { name: def.name, args, raw };
  }
  const head = raw.split(/[:>]/)[0];
  const hint = CATALOG.includes(head) ? ` (bad arguments for ${head})` : '';
  throw new Error(`unknown predicate ${JSON.stringify(raw)}${hint}; catalog: ${CATALOG.join(', ')}`);
}

export function parseUntil(expr) {
  if (typeof expr !== 'string' || expr.trim() === '') throw new Error('until must be a non-empty predicate expression');
  const atoms = expr.split('&&').map(parseAtom);
  return { expr: expr.trim(), atoms, needsHerdr: atoms.some((a) => HERDR_ATOMS.includes(a.name)) };
}

// ---- snapshot -------------------------------------------------------------

function readText(p) {
  try { return readFileSync(p, 'utf8'); } catch { return null; }
}
function listDir(p) {
  try { return readdirSync(p); } catch { return []; }
}
function mtimeMs(p) {
  try { return statSync(p).mtimeMs; } catch { return null; }
}
function isDir(p) {
  try { return lstatSync(p).isDirectory(); } catch { return false; }
}

// The sha a project's main ref points at, read from the git dir without
// spawning git: loose ref first, then packed-refs.
export function readMainSha(gitDir) {
  const loose = readText(join(gitDir, 'refs', 'heads', 'main'));
  if (loose && loose.trim()) return loose.trim();
  const packed = readText(join(gitDir, 'packed-refs'));
  if (packed) {
    for (const line of packed.split('\n')) {
      const m = /^([0-9a-f]{40,64}) refs\/heads\/main$/.exec(line.trim());
      if (m) return m[1];
    }
  }
  return null;
}

export function parseMeta(text) {
  const out = {};
  for (const line of (text ?? '').split('\n')) {
    const i = line.indexOf('=');
    if (i > 0) out[line.slice(0, i)] = line.slice(i + 1).replace(/\r$/, '');
  }
  return out;
}

export function snapshotHome(home, nowMs = Date.now()) {
  const state = join(home, 'state');
  const data = join(home, 'data');
  const taskIds = listDir(state).filter((f) => f.endsWith('.meta') && !f.startsWith('.')).map((f) => f.slice(0, -5)).sort();
  const meta = {};
  const status = {};
  const inbox = {};
  for (const id of taskIds) {
    meta[id] = parseMeta(readText(join(state, `${id}.meta`)));
    status[id] = readText(join(state, `${id}.status`)) ?? '';
    const box = join(state, `${id}.inbox`);
    inbox[id] = {
      pending: listDir(box).filter((f) => f !== 'handled' && !f.startsWith('.')).length,
      handled: listDir(join(box, 'handled')).filter((f) => !f.startsWith('.')).length,
    };
  }
  // Status files of tasks whose meta is already gone still carry the verbs
  // they reached; a done: line survives cleanup long enough to be read.
  for (const f of listDir(state)) {
    if (f.endsWith('.status') && !f.startsWith('.')) {
      const id = f.slice(0, -7);
      if (!(id in status)) status[id] = readText(join(state, f)) ?? '';
    }
  }
  const reports = {};
  for (const d of listDir(data)) {
    const text = readText(join(data, d, 'report.md'));
    if (text !== null) reports[d] = text;
  }
  const projects = {};
  for (const name of listDir(join(home, 'projects'))) {
    const gitDir = join(home, 'projects', name, '.git');
    if (!isDir(gitDir)) continue;
    projects[name] = { gitDir: true, mainSha: readMainSha(gitDir) };
  }
  const wake = readText(join(state, '.wake-queue'));
  return {
    home,
    nowMs,
    lock: (readText(join(state, '.lock')) ?? '').trim() || null,
    projectsMd: readText(join(data, 'projects.md')),
    backlogMd: readText(join(data, 'backlog.md')),
    projects,
    taskIds,
    meta,
    status,
    inbox,
    reports,
    wakeQueueLines: wake === null ? 0 : wake.split('\n').filter((l) => l.trim() !== '').length,
    beaconMtimeMs: mtimeMs(join(state, '.last-watcher-beat')),
    // Filled by the wait loop when an atom needs it: { tabLabels: string[], panes: { [paneId]: boolean } }.
    herdr: null,
    // Filled by the wait loop: { [name]: { sha, count } }.
    gitAhead: {},
  };
}

// Count the list items under one "## <section>" heading of a tasks-axi
// markdown backlog, stopping at the next heading.
export function backlogSectionItems(text, section) {
  if (!text) return 0;
  let inside = false;
  let count = 0;
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\r$/, '');
    if (/^##\s/.test(line)) { inside = new RegExp(`^##\\s+${section}\\s*$`, 'i').test(line); continue; }
    if (inside && /^- \[.\]/.test(line)) count += 1;
  }
  return count;
}

// Every herdr pane id a task record names, so the herdr facts can be fetched.
export function recordedPaneIds(snap) {
  return Object.values(snap.meta).map((m) => m.herdr_pane_id || (m.window || '').replace(/^[^:]*:/, '')).filter(Boolean);
}

// ---- evaluation -----------------------------------------------------------

// ctx: { lockBaseline: string|null, seeds: { [name]: sha }, seenTaskIds: Set<string> }
// Returns { ok, reason, needs } where needs names a herdr fact the snapshot
// lacks ('tabs' | 'panes'); ok is then false until the wait loop supplies it.
export function evaluateAtom(atom, snap, ctx) {
  const a = atom.args;
  switch (atom.name) {
    case 'projects.registered': {
      const row = new RegExp(`^- ${a.name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} `, 'm').test(snap.projectsMd ?? '');
      const cloned = Boolean(snap.projects[a.name]?.gitDir);
      return { ok: row && cloned, reason: `registry row ${row}, clone ${cloned}` };
    }
    case 'tasks.count':
      return { ok: snap.taskIds.length >= a.n, reason: `${snap.taskIds.length} task record(s)` };
    case 'backlog.inflight': {
      const n = backlogSectionItems(snap.backlogMd, 'In flight');
      return { ok: n >= a.n, reason: `${n} item(s) In flight` };
    }
    case 'tasks.kind': {
      const hit = snap.taskIds.filter((id) => snap.meta[id].kind === a.kind);
      return { ok: hit.length > 0, reason: hit.length ? `kind=${a.kind}: ${hit.join(' ')}` : `no task record with kind=${a.kind}` };
    }
    case 'status.verb': {
      const re = new RegExp(`^${a.verb}:`, 'm');
      const hit = Object.entries(snap.status).filter(([, t]) => re.test(t)).map(([id]) => id);
      return { ok: hit.length > 0, reason: hit.length ? `${a.verb}: from ${hit.join(' ')}` : `no ${a.verb}: line yet` };
    }
    case 'report.exists': {
      const hit = Object.entries(snap.reports).filter(([, t]) => t.trim() !== '').map(([id]) => id);
      return { ok: hit.length > 0, reason: hit.length ? `report from ${hit.join(' ')}` : 'no report.md yet' };
    }
    case 'report.mentions': {
      const needle = a.needle.toLowerCase();
      const hit = Object.entries(snap.reports).filter(([, t]) => t.toLowerCase().includes(needle)).map(([id]) => id);
      return { ok: hit.length > 0, reason: hit.length ? `report mentions ${a.needle}` : `no report mentions ${a.needle}` };
    }
    case 'inbox.handled': {
      const hit = Object.entries(snap.inbox).filter(([, b]) => b.handled > 0).map(([id]) => id);
      return { ok: hit.length > 0, reason: hit.length ? `steer handled by ${hit.join(' ')}` : 'no handled steer yet' };
    }
    case 'lock.held':
      return { ok: snap.lock !== null, reason: snap.lock ? `lock ${snap.lock}` : 'no lock' };
    case 'lock.rotated': {
      const ok = snap.lock !== null && ctx.lockBaseline !== undefined && snap.lock !== ctx.lockBaseline;
      return { ok, reason: `lock ${snap.lock ?? 'absent'} vs baseline ${ctx.lockBaseline ?? 'none'}` };
    }
    case 'git.ahead': {
      const proj = snap.projects[a.name];
      if (!proj?.mainSha) return { ok: false, reason: `projects/${a.name} has no main yet` };
      const seed = ctx.seeds?.[a.name];
      if (seed && proj.mainSha === seed) return { ok: a.n === 0, reason: 'main still at the seeded base' };
      const cached = snap.gitAhead[a.name];
      if (!cached || cached.sha !== proj.mainSha) return { ok: false, reason: `main moved to ${proj.mainSha.slice(0, 7)}; count pending`, needs: 'git' };
      return { ok: cached.count >= a.n, reason: `${cached.count} commit(s) ahead of the base` };
    }
    case 'home.clean':
      return { ok: snap.taskIds.length === 0, reason: snap.taskIds.length ? `task records remain: ${snap.taskIds.join(' ')}` : 'no task record' };
    case 'tabs.clean': {
      if (!snap.herdr?.tabLabels) return { ok: false, reason: 'tab list not fetched', needs: 'tabs' };
      const want = new Set([...(ctx.seenTaskIds ?? [])].map((id) => `fm-${id}`));
      const open = snap.herdr.tabLabels.filter((l) => want.has(l));
      return { ok: open.length === 0, reason: open.length ? `task tabs still open: ${open.join(' ')}` : 'no task tab open' };
    }
    case 'worker.alive': {
      const ids = recordedPaneIds(snap);
      if (ids.length === 0) return { ok: false, reason: 'no task record names a pane' };
      if (!snap.herdr?.panes) return { ok: false, reason: 'pane liveness not fetched', needs: 'panes' };
      const dead = ids.filter((p) => !snap.herdr.panes[p]);
      return { ok: dead.length === 0, reason: dead.length ? `pane(s) gone: ${dead.join(' ')}` : `pane(s) answer: ${ids.join(' ')}` };
    }
    case 'wake.empty':
      return { ok: snap.wakeQueueLines === 0, reason: `${snap.wakeQueueLines} queued notification(s)` };
    case 'beacon.fresh': {
      if (snap.beaconMtimeMs === null) return { ok: false, reason: 'no watcher beacon' };
      const age = snap.nowMs - snap.beaconMtimeMs;
      return { ok: age < 300_000, reason: `beacon ${Math.round(age / 1000)} s old` };
    }
    case 'file.contains': {
      const p = resolve(snap.home, a.rel);
      if (!p.startsWith(resolve(snap.home) + sep)) return { ok: false, reason: 'path escapes the home' };
      const text = readText(p);
      if (text === null) return { ok: false, reason: `${a.rel} missing` };
      return { ok: text.includes(a.needle), reason: text.includes(a.needle) ? `${a.rel} contains it` : `${a.rel} lacks it` };
    }
    default:
      return { ok: false, reason: `unknown atom ${atom.name}` };
  }
}

// Conjunction with short-circuit: the first false atom decides, so a herdr
// fact is only requested once every cheaper fs atom already holds.
export function evaluateUntil(parsed, snap, ctx) {
  for (const atom of parsed.atoms) {
    const r = evaluateAtom(atom, snap, ctx);
    if (!r.ok) return { ok: false, reason: `${atom.raw}: ${r.reason}`, needs: r.needs, atom };
  }
  return { ok: true, reason: 'holds' };
}

export { existsSync };
