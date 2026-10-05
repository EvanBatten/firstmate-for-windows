import { watch } from 'node:fs';
import { spawn } from 'node:child_process';
import { snapshotHome, evaluateUntil, recordedPaneIds } from './predicates.mjs';

export const DEBOUNCE_MS = 40;
export const SAFETY_TICK_MS = 1000;
export const LIVENESS_TICK_MS = 500;
// Minimum gap between two fetches of one fact kind inside one wait.
export const FACT_MIN_INTERVAL_MS = { git: 0, tabs: 3000, panes: 3000 };

// deps:
//   liveness()            -> { alive: boolean, reason: string }   (sync or async)
//   signals               -> { blocked: string|null }  set by the session's event stream
//   fetchHerdr(kind, snap)-> fills snap.herdr for kind 'tabs' | 'panes'
//   gitAhead              -> shared cache { [name]: { sha, count } } fetchFact fills
//   seeds                 -> { [name]: sha }
//   counters              -> { gitSpawns }
function observe(home, deps, onSnapshot) {
  const snap = snapshotHome(home);
  snap.gitAhead = deps.gitAhead;
  onSnapshot?.(snap);
  return snap;
}

// The one dispatcher for every `needs` value. It fills snap or a deps cache and never decides the claim.
export async function fetchFact(kind, { snap, atom, deps, home }) {
  if (kind === 'git') {
    const name = atom.args.name;
    const sha = snap.projects[name]?.mainSha;
    deps.gitAhead[name] = { sha, count: await gitAheadCount(home, name, deps.seeds?.[name], sha, deps.counters) };
    return;
  }
  snap.herdr = snap.herdr ?? {};
  await deps.fetchHerdr(kind, snap, recordedPaneIds(snap));
}

// Evaluates on one snapshot, fetching each outside fact the claim asks for once. With lastFetch,
// a fact asked for sooner than its minimum interval is not fetched and retryInMs says when to look again.
export async function holdsNow({ home, parsed, ctx, deps, onSnapshot, lastFetch }) {
  const snap = observe(home, deps, onSnapshot);
  const fetched = new Set();
  for (;;) {
    const r = evaluateUntil(parsed, snap, ctx);
    const key = r.needs && `${r.needs}:${r.atom.raw}`;
    if (r.ok || !r.needs || fetched.has(key)) return { ...r, snap };
    if (lastFetch) {
      const wait = FACT_MIN_INTERVAL_MS[r.needs] - (Date.now() - (lastFetch[r.needs] ?? 0));
      if (wait > 0) return { ...r, snap, retryInMs: wait };
      lastFetch[r.needs] = Date.now();
    }
    fetched.add(key);
    await fetchFact(r.needs, { snap, atom: r.atom, ctx, deps, home });
  }
}

export async function waitUntil({ home, parsed, ctx, budgetMs, deps, onSnapshot }) {
  const started = Date.now();
  const deadline = started + budgetMs;
  const lastFetch = {};
  let settled = false;
  let evaluating = false;
  let dirty = false;

  return new Promise((resolve) => {
    const timers = [];
    let watcher = null;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      for (const t of timers) clearTimeout(t);
      clearInterval(safety);
      clearInterval(live);
      watcher?.close();
      resolve({ ...result, ms: Date.now() - started });
    };

    const evaluate = async () => {
      if (settled) return;
      if (evaluating) { dirty = true; return; }
      evaluating = true;
      try {
        const r = await holdsNow({ home, parsed, ctx, deps, onSnapshot, lastFetch });
        if (r.ok) finish({ ok: true, reason: r.reason, snap: r.snap });
        else if (r.retryInMs) timers.push(setTimeout(evaluate, r.retryInMs));
      } finally {
        evaluating = false;
        if (dirty && !settled) { dirty = false; setTimeout(evaluate, 0); }
      }
    };

    let debounce = null;
    const wake = () => {
      if (debounce) clearTimeout(debounce);
      debounce = setTimeout(() => { debounce = null; evaluate(); }, DEBOUNCE_MS);
    };
    try {
      watcher = watch(home, { recursive: true, persistent: false }, wake);
      watcher.on('error', () => {});
    } catch {
      watcher = null; // the safety tick carries the wait alone
    }
    const safety = setInterval(evaluate, SAFETY_TICK_MS);
    const live = setInterval(async () => {
      if (settled) return;
      if (deps.signals?.blocked) {
        // A claim that already holds wins. A parked question only fails a
        // step whose until is still false.
        const snap = observe(home, deps, onSnapshot);
        const r = evaluateUntil(parsed, snap, ctx);
        if (r.ok) { finish({ ok: true, reason: r.reason, snap }); return; }
        finish({ ok: false, reason: `the primary stopped to ask a question: ${deps.signals.blocked}`, blocked: true });
        return;
      }
      const l = await deps.liveness();
      if (!l.alive) finish({ ok: false, reason: `the primary exited: ${l.reason}`, dead: true });
    }, LIVENESS_TICK_MS);
    timers.push(setTimeout(async () => {
      // One last look right at the deadline, so a claim that became true in
      // the final debounce window is not lost.
      const snap = observe(home, deps);
      const r = evaluateUntil(parsed, snap, ctx);
      finish(r.ok ? { ok: true, reason: r.reason, snap } : { ok: false, reason: `not within ${Math.round(budgetMs / 1000)} s: ${r.reason}`, timeout: true, snap });
    }, Math.max(0, deadline - Date.now())));
    evaluate();
  });
}

// `git rev-list --count <seed>..<sha>` in the project clone inside the home;
// one spawn per observed sha change, never per tick. Without a seed the count
// is 1 when main moved at all.
export function gitAheadCount(home, name, seed, sha, counters) {
  if (!seed) return Promise.resolve(sha ? 1 : 0);
  return new Promise((resolve) => {
    counters.gitSpawns = (counters.gitSpawns ?? 0) + 1;
    const child = spawn('git', ['-C', `${home}/projects/${name}`, 'rev-list', '--count', `${seed}..${sha}`], { stdio: ['ignore', 'pipe', 'ignore'], shell: false, windowsHide: true });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.on('error', () => resolve(0));
    child.on('close', (code) => resolve(code === 0 ? Number.parseInt(out.trim(), 10) || 0 : 0));
  });
}
