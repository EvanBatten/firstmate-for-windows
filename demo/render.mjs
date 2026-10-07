// Render the README demo from one recorded whole-session drive.
//   node render.mjs --run <run-dir> [--out <dir>] [--fps 30] [--jobs 4]
// <run-dir> holds rec/frames.jsonl (record.mjs) and evidence/captain.log (fm-drive).
// Writes <out>/firstmate-demo.mp4, <out>/demo.webp and <out>/check/ (one still per second).
// Exits 1 when demo.webp passes 8 MiB (README load budget) or the MP4 passes 10 MiB (GitHub's video upload limit).
import { chromium } from 'playwright-core';
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { ansiToHtmlLines } from './ansi.mjs';
import { redactor, scratchNamesIn } from './redact.mjs';

const here = fileURLToPath(new URL('.', import.meta.url));
const opt = Object.fromEntries(process.argv.slice(2).reduce((a, v, i, all) => (v.startsWith('--') ? [...a, [v.slice(2), all[i + 1]]] : a), []));
const run = resolve(opt.run);
const out = resolve(opt.out || join(here, 'out'));
const fps = Number(opt.fps || 30);
const jobs = Number(opt.jobs || 4);

const raw = readFileSync(join(run, 'rec/frames.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
const t0 = raw[0].t;
const says = readFileSync(join(run, 'evidence/captain.log'), 'utf8').trim().split('\n').map((l) => { const [ts, text] = l.split('\t'); return { at: Date.parse(ts) - t0, text }; });
if (says.length < 3) throw new Error(`captain.log has ${says.length} lines; the whole-session trace types 3`);

const { redact, leaks } = redactor({ scratchNames: scratchNamesIn(raw.map((f) => f.ansi)) });
const primary = raw[0].pane;
const panes = {};
const labels = {};
for (const f of raw) {
  const text = redact(f.ansi);
  const left = leaks(text.replace(/\x1b\[[0-9;]*m/g, ''));
  if (left.length) throw new Error(`frame ${f.pane} at ${f.rel} ms still shows ${left.join(', ')}`);
  (panes[f.pane] ??= []).push({ rel: f.rel, lines: ansiToHtmlLines(text) });
  labels[f.pane] = f.label;
}
const workers = Object.keys(panes).filter((p) => p !== primary).sort((a, b) => panes[a][0].rel - panes[b][0].rel);
const plain = (s) => s.replace(/<[^>]+>/g, '').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
const cols = Math.max(...Object.values(panes).flat().flatMap((f) => f.lines.map((l) => [...plain(l)].length)));
const rows = Math.max(...Object.values(panes).flat().map((f) => f.lines.length));

const A = {
  req: says[0].at, steer: says[1].at, land: says[2].at, end: raw.at(-1).rel,
  spawn: workers.map((p) => panes[p][0].rel),
};
const busiest = (from, to) => workers.map((p) => [p, panes[p].filter((f) => f.rel >= from && f.rel <= to).length]).sort((a, b) => b[1] - a[1])[0][0];
const steered = busiest(A.steer, A.steer + 150_000);
const opening = says[0].text.split(/\s+/).slice(0, 3).join(' ');
const asked = panes[primary].find((f) => f.rel > A.req && f.lines.map(plain).join(' ').includes(opening))?.rel ?? A.req;

const BAR = 34; const PAD = 8;
const termW = (font) => Math.ceil(cols * font * 0.6) + 24;
const pW = termW(15); const pH = Math.ceil(rows * 15 * 1.22) + BAR + 2 * PAD;
const wW = termW(12.5); const gap = 30; const wGap = 18;
const wH = (pH - wGap * (workers.length - 1)) / workers.length;
const x0 = (1920 - (pW + gap + wW)) / 2; const y0 = 118;
const title = (p) => (p === primary ? 'first mate' : `crewmate · ${labels[p].replace(/^worker\s+/, '')}`);
const layout = { [primary]: { x: x0, y: y0, w: pW, h: pH, font: 15, title: title(primary) } };
workers.forEach((p, i) => { layout[p] = { x: x0 + pW + gap, y: y0 + i * (wH + wGap), w: wW, h: wH, font: 12.5, title: title(p) }; });

const STAGE = { x: x0 - 16, y: y0 - 16, w: pW + gap + wW + 32, h: pH + 32 };
const CREW = { x: x0 + pW + gap - 16, y: y0 - 16, w: wW + 32, h: Math.min(2, workers.length) * (wH + wGap) - wGap + 32 };
const SAFE = { x: 40, y: 96, w: 1840, h: 834 };
const win = (p, top = 0, bottom = 1) => {
  const r = layout[p]; const body = r.h - BAR;
  const y = r.y + BAR + body * top; const h = body * (bottom - top) + (top === 0 ? BAR : 0);
  return { x: r.x - 16, y: top === 0 ? r.y - 16 : y - 8, w: r.w + 32, h: h + 32 };
};
const s = (ms) => ms / 1000;
const REPORT = win(primary, 0.22, 0.86);

const scenes = [
  { card: true, dur: 3.2, tag: 'Talk to <b>one agent</b>. Ship with <b>a crew</b>.', src: [s(A.req), s(A.req)], cams: [{ at: 0, cam: STAGE }] },
  { dur: 4.2, src: [s(asked) - 0.3, s(asked) + 6], cams: [{ at: 0, cam: win(primary, 0, 0.52) }], focus: [{ at: 0, on: [primary] }], captions: [{ at: 0, text: 'You ask for three changes, in plain words' }] },
  { dur: 5, src: [s(asked) + 6, s(A.spawn[0]) - 4], cams: [{ at: 0, cam: win(primary, 0.42, 1) }], focus: [{ at: 0, on: [primary] }], captions: [{ at: 0, text: 'The <b>first mate</b> plans the work' }] },
  { dur: 9, src: [s(A.spawn[0]) - 4, s(A.steer) - 3], cams: [{ at: 0, cam: STAGE }, { at: 0.55, cam: CREW }], focus: [{ at: 0, on: null }, { at: 0.55, on: workers }], captions: [{ at: 0, text: 'It spawns a <b>crew</b>, each in its own worktree' }] },
  { dur: 7.5, src: [s(A.steer) - 3, s(A.steer) + 80], cams: [{ at: 0, cam: win(primary, 0.5, 1) }, { at: 0.5, cam: win(steered, 0, 1) }],
    focus: [{ at: 0, on: [primary] }, { at: 0.5, on: [steered] }],
    captions: [{ at: 0, text: 'Change your mind mid-flight' }, { at: 0.5, text: 'It relays the change to the right crewmate' }] },
  { dur: 5.5, src: [s(A.steer) + 80, s(A.land)], cams: [{ at: 0, cam: CREW }, { at: 0.6, cam: STAGE }], focus: [{ at: 0, on: workers }, { at: 0.6, on: null }], captions: [{ at: 0, text: 'Each crewmate reports back' }] },
  { dur: 7.5, src: [s(A.land), s(A.end) - 4], cams: [{ at: 0, cam: win(primary, 0.45, 1) }, { at: 0.55, cam: STAGE }], focus: [{ at: 0, on: [primary] }, { at: 0.55, on: null }], fadeWorkers: [0.62, 0.95],
    captions: [{ at: 0, text: 'It checks each one, then lands it on main' }, { at: 0.55, text: 'Then it cleans up after itself' }] },
  { dur: 6.5, src: [s(A.end), s(A.end)], cams: [{ at: 0, cam: REPORT }], focus: [{ at: 0, on: [primary] }], hideWorkers: true, captions: [{ at: 0, text: 'Done, and reported back to you' }] },
  { card: true, dur: 4.2, tag: 'Talk to <b>one agent</b>. Ship with <b>a crew</b>.', src: [s(A.end), s(A.end)], cams: [{ at: 0, cam: REPORT }], hideWorkers: true },
];

const ease = (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x < 0.5 ? 4 * x * x * x : 1 - (-2 * x + 2) ** 3 / 2);
const mix = (a, b, k) => ({ x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k, w: a.w + (b.w - a.w) * k, h: a.h + (b.h - a.h) * k });
const pick = (list, f) => list.filter((e) => e.at <= f).at(-1);
const total = scenes.reduce((n, sc) => n + sc.dur, 0);
const clock = (sec) => `${Math.floor(sec / 60)}:${String(Math.floor(sec % 60)).padStart(2, '0')}`;

function stateAt(t) {
  let start = 0; let i = 0;
  while (i < scenes.length - 1 && t >= start + scenes[i].dur) { start += scenes[i].dur; i += 1; }
  const sc = scenes[i]; const local = t - start; const f = local / sc.dur;
  const steps = Math.floor(local * 6) / 6 / sc.dur;
  const src = sc.src[0] + (sc.src[1] - sc.src[0]) * Math.min(1, steps);
  const smooth = sc.src[0] + (sc.src[1] - sc.src[0]) * f;
  const key = pick(sc.cams, f); const keyIdx = sc.cams.indexOf(key);
  const prevCam = keyIdx > 0 ? sc.cams[keyIdx - 1].cam : (i > 0 ? scenes[i - 1].cams.at(-1).cam : key.cam);
  const cam = mix(prevCam, key.cam, ease((local - key.at * sc.dur) / 1.1));
  const cap = sc.captions ? pick(sc.captions, f) : null;
  const capStart = cap ? start + cap.at * sc.dur : 0;
  const nextCap = sc.captions?.find((c) => c.at > f);
  const capEnd = nextCap ? start + nextCap.at * sc.dur : start + sc.dur;
  const capAlpha = cap ? Math.min(1, (t - capStart) / 0.35, (capEnd - t) / 0.25) : 0;
  const fadeIn = i === 1 ? Math.min(1, local / 0.6) : 1;
  const cardAlpha = sc.card ? Math.min(1, i === 0 ? 1 - Math.max(0, local - (sc.dur - 0.6)) / 0.6 : local / 0.6) : 0;
  const alpha = {}; const dim = {};
  for (const p of workers) {
    const first = panes[p][0].rel;
    alpha[p] = Math.max(0, Math.min(1, (smooth * 1000 - first) / Math.max(1, (sc.src[1] - sc.src[0]) / sc.dur * 1000 * 0.5)));
    if (sc.fadeWorkers) { const [a, b] = sc.fadeWorkers; const k = workers.indexOf(p) / workers.length; alpha[p] *= 1 - ease((f - a - k * 0.12) / (b - a - 0.24)); }
    if (sc.hideWorkers) alpha[p] = 0;
  }
  const fKey = sc.focus ? pick(sc.focus, f) : { at: 0, on: null };
  const fIdx = sc.focus ? sc.focus.indexOf(fKey) : -1;
  const fPrev = fIdx > 0 ? sc.focus[fIdx - 1] : (scenes[i - 1]?.focus?.at(-1) ?? { on: null });
  const dimmed = (key, p) => (key.on && !key.on.includes(p) ? 1 : 0);
  const fk = ease((local - fKey.at * sc.dur) / 0.6);
  for (const p of [primary, ...workers]) dim[p] = dimmed(fPrev, p) + (dimmed(fKey, p) - dimmed(fPrev, p)) * fk;
  const speed = (sc.src[1] - sc.src[0]) / sc.dur;
  const chip = sc.card ? '' : `<span>${clock(Math.max(0, src - s(A.req)))} elapsed</span>${speed > 1.5 ? `<span class="sp">${Math.round(speed)}× speed</span>` : ''}`;
  return { srcMs: src * 1000, cam, safe: SAFE, caption: cap?.text ?? '', capAlpha: Math.max(0, capAlpha) * fadeIn, chip, stageAlpha: sc.card ? 1 - cardAlpha : 1, cardAlpha, cardTag: sc.tag ?? '', cardScale: sc.card ? 1 + 0.03 * f : 1, alpha, dim };
}

const frameDir = join(out, 'frames');
const checkDir = join(out, 'check');
for (const d of [frameDir, checkDir]) { rmSync(d, { recursive: true, force: true }); mkdirSync(d, { recursive: true }); }
const n = Math.round(total * fps);
const started = Date.now();
const browser = await chromium.launch({ channel: process.env.FM_DEMO_CHROME ? undefined : 'chrome', executablePath: process.env.FM_DEMO_CHROME });
await Promise.all(Array.from({ length: jobs }, async (_, j) => {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
  await page.goto(pathToFileURL(join(here, 'stage.html')).href);
  await page.evaluate(() => document.fonts.ready);
  await page.evaluate(([p, l]) => window.setup(p, l), [panes, layout]);
  await page.evaluate(() => Promise.all([...document.fonts].map((f) => f.load())));
  for (let k = j; k < n; k += jobs) {
    await page.evaluate((st) => window.seek(st), stateAt(k / fps));
    await page.screenshot({ path: join(frameDir, `f${String(k).padStart(5, '0')}.jpg`), type: 'jpeg', quality: 94 });
  }
}));
await browser.close();
const renderMs = Date.now() - started;

const ff = (args) => execFileSync('ffmpeg', ['-y', '-loglevel', 'error', ...args], { stdio: 'inherit' });
const seq = ['-framerate', String(fps), '-i', join(frameDir, 'f%05d.jpg')];
const mp4 = join(out, 'firstmate-demo.mp4');
ff([...seq, '-c:v', 'libx264', '-preset', 'slow', '-crf', '27', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', mp4]);
const webp = join(out, 'demo.webp');
ff(['-i', mp4, '-vf', 'fps=10,scale=1120:-2:flags=lanczos', '-c:v', 'libwebp_anim', '-quality', '68', '-compression_level', '2', '-loop', '0', '-an', webp]);
ff(['-i', mp4, '-vf', 'fps=1,scale=960:-2', join(checkDir, 's%03d.jpg')]);
const sizes = Object.fromEntries([mp4, webp].map((p) => [p, Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=size', '-of', 'csv=p=0', p]).toString().trim())]));
const summary = { seconds: total, frames: n, renderMs, anchorsSec: Object.fromEntries(Object.entries(A).map(([k, v]) => [k, Array.isArray(v) ? v.map(s) : s(v)])), steered: title(steered), sizes };
writeFileSync(join(out, 'render.json'), `${JSON.stringify(summary, null, 2)}\n`);
rmSync(frameDir, { recursive: true, force: true });
console.log(JSON.stringify(summary));
const over = [[webp, 8 * 2 ** 20], [mp4, 10 * 2 ** 20]].filter(([p, limit]) => sizes[p] > limit);
for (const [p, limit] of over) console.error(`render.mjs: ${p} is ${sizes[p]} bytes, over ${limit}`);
if (over.length) process.exit(1);
