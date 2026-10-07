// Record what a driven firstmate session shows: the primary pane plus every worker pane
// the home's task records name, as visible-screen ANSI frames in <out>/frames.jsonl.
//   node record.mjs --out <dir> --pane <primary-pane-id> --home <home> [--session s] [--interval ms]
// Stops when <out>/STOP exists or the primary pane cannot be read for 30 s.
import { spawn } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const args = Object.fromEntries(process.argv.slice(2).reduce((a, v, i, all) => (v.startsWith('--') ? [...a, [v.slice(2), all[i + 1]]] : a), []));
const out = args.out;
const interval = Number(args.interval || 1000);
mkdirSync(out, { recursive: true });
const framesFile = join(out, 'frames.jsonl');
const sessionArgs = args.session ? ['--session', args.session] : [];

function herdr(argv) {
  return new Promise((res) => {
    const c = spawn('herdr', [...argv, ...sessionArgs], { stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true });
    let o = '';
    c.stdout.on('data', (d) => { o += d; });
    c.on('error', () => res(null));
    c.on('close', (code) => res(code === 0 ? o : null));
  });
}

function workerPanes() {
  const state = join(args.home, 'state');
  if (!existsSync(state)) return [];
  const panes = [];
  for (const f of readdirSync(state)) {
    if (!f.endsWith('.meta')) continue;
    try {
      const kv = Object.fromEntries(readFileSync(join(state, f), 'utf8').split('\n').map((l) => l.split('=')).filter((p) => p.length >= 2).map(([k, ...v]) => [k, v.join('=')]));
      if (kv.herdr_pane_id) panes.push({ pane: kv.herdr_pane_id, label: `worker ${kv.endpoint_task_id || f.replace(/\.meta$/, '')}` });
    } catch { /* a record mid-write is read on the next tick */ }
  }
  return panes;
}

const last = new Map();
let primaryMissSince = null;
const t0 = Date.now();
for (;;) {
  if (existsSync(join(out, 'STOP'))) break;
  const targets = [{ pane: args.pane, label: 'first mate' }, ...workerPanes().filter((w) => w.pane !== args.pane)];
  const tick = Date.now();
  await Promise.all(targets.map(async ({ pane, label }) => {
    const ansi = await herdr(['pane', 'read', pane, '--source', 'visible', '--ansi']);
    if (pane === args.pane) primaryMissSince = ansi == null ? (primaryMissSince ?? tick) : null;
    if (ansi == null || last.get(pane) === ansi) return;
    last.set(pane, ansi);
    appendFileSync(framesFile, `${JSON.stringify({ t: tick, rel: tick - t0, pane, label, ansi })}\n`);
  }));
  if (primaryMissSince && Date.now() - primaryMissSince > 30_000) break;
  await new Promise((r) => setTimeout(r, Math.max(0, interval - (Date.now() - tick))));
}
