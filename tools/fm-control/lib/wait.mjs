import { watch } from "node:fs";
import { join } from "node:path";
import { predicate } from "./predicates.mjs";
import { snapshotHome } from "./snapshot.mjs";

const DEBOUNCE_MS = 25;
const DEADLINE_TICK_MS = 50;

/**
 * Rebuild the snapshot on home writes and on a short deadline tick.
 * The tick is a deadline, not a herdr poll and not a 5s sleep.
 * Returns { ok, ms, dead }.
 */
export async function waitUntil({
  home,
  until,
  budgetMs,
  stamps,
  isDead,
  now = Date.now,
}) {
  const pred = predicate(until);
  const started = now();
  const deadline = started + budgetMs;
  const evalNow = () => pred(snapshotHome(home, stamps));
  if (evalNow()) return { ok: true, ms: 0, dead: false };
  if (typeof isDead === "function" && isDead()) {
    return { ok: false, ms: now() - started, dead: true };
  }

  return new Promise((resolve) => {
    let settled = false;
    let debounce = null;
    const watchers = [];

    const finish = (ok, dead = false) => {
      if (settled) return;
      settled = true;
      clearTimeout(debounce);
      clearInterval(tick);
      for (const w of watchers) {
        try {
          w.close();
        } catch {
          /* ignore */
        }
      }
      resolve({ ok, ms: now() - started, dead });
    };

    const check = () => {
      if (now() >= deadline) return finish(false, false);
      if (typeof isDead === "function" && isDead()) return finish(false, true);
      if (evalNow()) return finish(true, false);
    };

    const onFs = () => {
      clearTimeout(debounce);
      debounce = setTimeout(check, DEBOUNCE_MS);
    };

    for (const rel of [".", "state", "data", "projects"]) {
      try {
        watchers.push(watch(join(home, rel), { recursive: true }, onFs));
      } catch {
        /* directory may not exist yet */
      }
    }

    const tick = setInterval(check, DEADLINE_TICK_MS);
    check();
  });
}
