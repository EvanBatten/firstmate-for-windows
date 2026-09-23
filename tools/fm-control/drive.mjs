#!/usr/bin/env node
// fm-control: drive one firstmate session through a captain trace and report
// how long each claim took to become true.
//
//   node tools/fm-control/drive.mjs run   <trace.json>   drive a real session; JSON result on stdout
//   node tools/fm-control/drive.mjs check <trace.json>   validate the trace only; no herdr call
//
// Exit codes:
//   0  every step held (pass true)
//   1  a step did not hold: budget elapsed, primary died, or it parked on a question
//   2  the trace was refused before any herdr call (unknown predicate, startup-only claims, bad shape)
//   3  the environment failed: herdr unusable, clone failed, primary never became ready
//
// Result shape (one JSON object, always printed for run, even on failure):
//   { feature, wallMs, pass, readyMs, predicateMs,
//     steps: [{ say, until, ms, ok, reason, sayMs? , relaunchMs? }],
//     overhead: { transport, herdrCalls, spawns, herdrSpawns, gitSpawns, setupSpawns, cleanupSpawns, setupMs, closeMs },
//     evidence, error? }
// predicateMs is the time spent waiting for claims; readyMs the first launch; the rest of wallMs is
// the driver's own setup, typing, relaunch and cleanup, which the overhead block breaks down.
// The trace grammar, predicate catalog and environment knobs are documented in lib/trace.mjs,
// lib/predicates.mjs, lib/herdr.mjs and lib/session.mjs.

import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { loadTrace, interpolate, TraceError, RELAUNCH } from './lib/trace.mjs';
import { Session } from './lib/session.mjs';
import { waitUntil } from './lib/wait.mjs';
import { HerdrError } from './lib/herdr.mjs';

const T0 = Date.now();
const log = (line) => { if (process.env.FM_CONTROL_QUIET !== '1') process.stderr.write(`fm-control: ${line}\n`); };

function usage(code) {
  process.stderr.write('usage: node tools/fm-control/drive.mjs run|check <trace.json>\n');
  process.exit(code);
}

function emit(obj) {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
}

async function main(argv) {
  const [cmd, file] = argv;
  if (!cmd || !file || !['run', 'check'].includes(cmd)) usage(2);

  let trace;
  try {
    trace = loadTrace(file);
  } catch (err) {
    if (err instanceof TraceError) {
      process.stderr.write(`fm-control: trace rejected: ${err.message}\n`);
      emit({ feature: null, pass: false, rejected: err.message });
      return 2;
    }
    throw err;
  }
  if (cmd === 'check') {
    emit({ feature: trace.feature, ok: true, steps: trace.steps.map((s) => ({ say: s.say, until: s.until, budgetSec: s.budgetSec ?? null })) });
    return 0;
  }
  return run(trace);
}

async function run(trace) {
  const env = process.env;
  const defaultBudgetMs = Number.parseInt(env.FM_CONTROL_UNTIL_MS || '1200000', 10);
  const session = new Session({ trace, env, log });
  const result = {
    feature: trace.feature,
    wallMs: 0,
    pass: false,
    readyMs: null,
    predicateMs: 0,
    steps: [],
    overhead: {},
    evidence: session.evidenceDir,
  };
  let exitCode = 1;
  let closing = null;
  const finish = async () => {
    if (!closing) closing = session.close().catch((err) => { log(`cleanup problem: ${err.message}`); return 0; });
    return closing;
  };
  const onSignal = async (sig) => {
    log(`received ${sig}; closing what this run created`);
    result.error = `interrupted by ${sig}`;
    await finish();
    process.exit(130);
  };
  process.once('SIGINT', onSignal);
  process.once('SIGTERM', onSignal);

  try {
    const setupStart = Date.now();
    await session.open();
    result.overhead.setupMs = Date.now() - setupStart;
    const vars = { projectOrigin: session.projectOrigin ?? '', home: session.home };
    const steps = interpolate(trace, vars).steps;

    result.readyMs = await session.launch();
    log(`primary ready in ${result.readyMs} ms (pid ${session.primaryPid}, lock ${session.lockAtReady})`);

    const gitAhead = {};
    const deps = {
      liveness: () => session.liveness(),
      signals: session.signals,
      fetchHerdr: (kind, snap, ids) => session.fetchHerdr(kind, snap, ids),
      gitAhead,
      seeds: session.seeds,
      counters: session.counters,
    };

    let allOk = true;
    for (const [i, step] of steps.entries()) {
      const rec = { say: step.say, until: step.until, ms: 0, ok: false, reason: '' };
      result.steps.push(rec);
      if (step.say === RELAUNCH) {
        rec.relaunchMs = await session.relaunch();
        log(`step ${i + 1}: relaunched in ${rec.relaunchMs} ms; waiting for ${step.until}`);
      } else if (step.say !== '') {
        rec.sayMs = await session.say(step.say);
        log(`step ${i + 1}: said ${JSON.stringify(step.say.length > 60 ? `${step.say.slice(0, 57)}...` : step.say)}; waiting for ${step.until}`);
      } else {
        log(`step ${i + 1}: waiting for ${step.until}`);
      }
      const budgetMs = step.budgetSec ? Math.round(step.budgetSec * 1000) : defaultBudgetMs;
      const ctx = { lockBaseline: session.lockBaseline, seeds: session.seeds, seenTaskIds: session.seenTaskIds };
      const r = await waitUntil({ home: session.home, parsed: step.parsed, ctx, budgetMs, deps, onSnapshot: (snap) => session.noteTaskIds(snap) });
      rec.ms = r.ms;
      rec.ok = r.ok;
      rec.reason = r.reason;
      result.predicateMs += r.ms;
      log(`step ${i + 1}: ${r.ok ? 'holds' : 'FAILED'} after ${r.ms} ms (${r.reason})`);
      if (!r.ok) {
        allOk = false;
        try { session.snapshot(`step${i + 1}-failed`, await session.paneText()); } catch { /* pane may be gone */ }
        break;
      }
    }
    result.pass = allOk && result.steps.length === steps.length && result.steps.at(-1).ok;
    exitCode = result.pass ? 0 : 1;
  } catch (err) {
    result.error = err.message;
    exitCode = err instanceof HerdrError || err instanceof TraceError ? err.exitCode : 3;
    log(`run failed: ${err.message}`);
  } finally {
    const closeStart = Date.now();
    await finish();
    result.overhead.closeMs = Date.now() - closeStart;
    const h = session.herdr?.counters ?? { calls: 0, spawns: 0 };
    const c = session.counters;
    result.overhead = {
      transport: session.herdr?.transport ?? null,
      herdrCalls: h.calls,
      spawns: h.spawns + c.gitSpawns + c.setupSpawns + c.cleanupSpawns,
      herdrSpawns: h.spawns,
      gitSpawns: c.gitSpawns,
      setupSpawns: c.setupSpawns,
      cleanupSpawns: c.cleanupSpawns,
      setupMs: result.overhead.setupMs ?? null,
      closeMs: result.overhead.closeMs,
    };
    result.wallMs = Date.now() - T0;
    try { writeFileSync(join(session.evidenceDir, 'result.json'), `${JSON.stringify(result, null, 2)}\n`); } catch { /* evidence is best effort */ }
    emit(result);
  }
  return exitCode;
}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (err) => {
    process.stderr.write(`fm-control: ${err?.stack ?? err}\n`);
    process.exit(3);
  },
);
