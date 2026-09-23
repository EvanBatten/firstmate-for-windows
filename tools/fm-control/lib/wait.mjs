// The wait primitive: a deadline, a file watcher, and a pure predicate.
//
// waitUntil resolves as soon as the parsed `until` holds on a fresh home
// snapshot, when the budget elapses, or when the primary is found dead or
// parked on a question. It never sleeps in a fixed poll loop and never reads
// the pane every second: fs.watch on the home wakes it (debounced so one
// multi-file write is one snapshot), a 1 s safety tick re-reads the cheap fs
// facts in case a watch event was lost, and liveness is checked every 500 ms
// from the pid herdr reported, which is a kill(pid, 0) and not a herdr call.
// A dead-primary pane-prompt check is event-driven from the session's 10 s
// status query, not this loop.

import { watch } from 'node:fs';
import { spawn } from 'node:child_process';
import { snapshotHome, evaluateUntil, recordedPaneIds } from './predicates.mjs';

export const DEBOUNCE_MS = 40;
export const SAFETY_TICK_MS = 1000;
export const LIVENESS_TICK_MS = 500;
export const HERDR_FACT_MIN_INTERVAL_MS = 3000;

// deps:
//   liveness()            -> { alive: boolean, reason: string }   (sync or async)
//   signals               -> { blocked: string|null }  set by the session's event stream
//   fetchHerdr(kind, snap)-> fills snap.herdr for kind 'tabs' | 'panes'
//   gitAhead              -> shared cache { [name]: { sha, count } } this function fills
//   seeds                 -> { [name]: sha }
//   counters              -> { gitSpawns }
export async function waitUntil({ home, parsed, ctx, budgetMs, deps, onSnapshot }) {
  const started = Date.now();
  const deadline = started + budgetMs;
  let lastHerdrFetch = { tabs: 0, panes: 0 };
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
        // Re-evaluate until nothing new is needed: a herdr or git fact fetched
        // for one atom can make the next atom the deciding one.
        for (let round = 0; round < 6 && !settled; round++) {
          const snap = snapshotHome(home);
          snap.gitAhead = deps.gitAhead;
          onSnapshot?.(snap);
          const r = evaluateUntil(parsed, snap, ctx);
          if (r.ok) { finish({ ok: true, reason: r.reason, snap }); return; }
          if (r.needs === 'git') {
            const name = r.atom.args.name;
            const sha = snap.projects[name]?.mainSha;
            const seed = deps.seeds?.[name];
            const count = await gitAheadCount(home, name, seed, sha, deps.counters);
            deps.gitAhead[name] = { sha, count };
            continue;
          }
          if (r.needs === 'tabs' || r.needs === 'panes') {
            const now = Date.now();
            if (now - lastHerdrFetch[r.needs] < HERDR_FACT_MIN_INTERVAL_MS) {
              timers.push(setTimeout(evaluate, HERDR_FACT_MIN_INTERVAL_MS - (now - lastHerdrFetch[r.needs])));
              return;
            }
            lastHerdrFetch[r.needs] = now;
            snap.herdr = snap.herdr ?? {};
            await deps.fetchHerdr(r.needs, snap, recordedPaneIds(snap));
            const again = evaluateUntil(parsed, snap, ctx);
            if (again.ok) { finish({ ok: true, reason: again.reason, snap }); return; }
            if (again.needs === r.needs) return; // still lacking; wait for the next wake
            continue;
          }
          return;
        }
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
        finish({ ok: false, reason: `the primary stopped to ask a question: ${deps.signals.blocked}`, blocked: true });
        return;
      }
      const l = await deps.liveness();
      if (!l.alive) finish({ ok: false, reason: `the primary exited: ${l.reason}`, dead: true });
    }, LIVENESS_TICK_MS);
    timers.push(setTimeout(async () => {
      // One last look right at the deadline, so a claim that became true in
      // the final debounce window is not lost.
      const snap = snapshotHome(home);
      snap.gitAhead = deps.gitAhead;
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
