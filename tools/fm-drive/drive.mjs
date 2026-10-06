#!/usr/bin/env node

import { writeFileSync } from 'node:fs';
import { join, basename } from 'node:path';
import { loadTrace, interpolate, refuseVacuousOnFreshHome, TraceError, RELAUNCH } from './lib/trace.mjs';
import { Session, driveRoot, REST_BEFORE_SAY_MS } from './lib/session.mjs';
import { waitUntil, holdsNow } from './lib/wait.mjs';
import { parseUntil, REMOTE_ATOMS } from './lib/predicates.mjs';
import { HerdrError } from './lib/herdr.mjs';
import { record, HEALTH } from './lib/ledger.mjs';

const T0 = Date.now();
const CAPTAIN_PATH = { claudeConfig: 'clean', hooks: 'repo', captainMd: 'untouched' };
const CAPTAIN_PATH_AT_CLOSE = { hooks: ['repo'], captainMd: ['untouched', 'written-after-say'] };
const log = (line) => { if (process.env.FM_DRIVE_QUIET !== '1') process.stderr.write(`fm-drive: ${line}\n`); };

function usage(code) {
  process.stderr.write('usage: node tools/fm-drive/drive.mjs run|check <trace.json>\n       node tools/fm-drive/drive.mjs record <result.json> [--head origin/<branch>]...\n');
  process.exit(code);
}

function emit(obj) {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
}

function refuse(err) {
  process.stderr.write(`fm-drive: trace rejected: ${err.message}\n`);
  emit({ feature: null, pass: false, rejected: err.message });
  return 2;
}

async function main(argv) {
  const [cmd, file, ...rest] = argv;
  if (!cmd || !file || !['run', 'check', 'record'].includes(cmd)) usage(2);
  if (cmd === 'record') return recordCommand(file, rest);

  let trace;
  try {
    trace = loadTrace(file, { root: driveRoot(process.env) });
  } catch (err) {
    if (err instanceof TraceError) return refuse(err);
    throw err;
  }
  return cmd === 'check' ? check(trace) : run(trace, basename(file, '.json'));
}

function recordCommand(file, rest) {
  const heads = [];
  for (let i = 0; i < rest.length; i += 2) {
    if (rest[i] !== '--head' || !rest[i + 1]) usage(2);
    heads.push(rest[i + 1]);
  }
  const out = record({ resultPath: file, root: driveRoot(process.env), heads });
  if (out.refused) {
    process.stderr.write(`fm-drive: record refused: ${out.refused}\n`);
    return 2;
  }
  for (const line of out.lines) process.stdout.write(`${line}\n`);
  return 0;
}

async function check(trace) {
  const session = new Session({ trace, env: process.env, log });
  try {
    await session.cloneFresh();
    refuseVacuousOnFreshHome(trace, session.home);
  } catch (err) {
    if (err instanceof TraceError) return refuse(err);
    throw err;
  } finally {
    session.removeScratch();
  }
  emit({ feature: trace.feature, ok: true, steps: trace.steps.map((s) => ({ say: s.say, until: s.until, budgetSec: s.budgetSec })) });
  return 0;
}

async function run(trace, traceName) {
  const env = process.env;
  const session = new Session({ trace, env, log });
  const result = {
    feature: trace.feature,
    trace: traceName,
    proves: trace.proves ?? {},
    code: null,
    wallMs: 0,
    pass: false,
    readyMs: null,
    operableMs: null,
    predicateMs: 0,
    fidelity: null,
    steps: [],
    overhead: {},
    evidence: session.evidenceDir,
  };
  let exitCode = 1;
  let recheckAtClose = false;
  let closing = null;
  const finish = async () => {
    if (!closing) closing = session.close({ keepEvidence: !result.rejected }).catch((err) => { log(`cleanup problem: ${err.message}`); return 0; });
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
    await session.prepare();
    result.code = session.code;
    refuseVacuousOnFreshHome(trace, session.home);
    result.fidelity = await session.fidelity();
    const broken = Object.entries(CAPTAIN_PATH).filter(([field, want]) => result.fidelity[field] !== want);
    if (broken.length) {
      throw new Error(`the prepared home is not the captain path: ${broken.map(([field]) => `fidelity.${field} is ${result.fidelity[field]}`).join(', ')}`);
    }
    recheckAtClose = true;
    await session.open();
    result.overhead.setupMs = Date.now() - setupStart;
    const vars = { projectOrigin: session.projectOrigin ?? '', home: session.home, remoteOrigin: session.remote?.url ?? '' };
    const steps = interpolate(trace, vars).steps;

    const gitAhead = {};
    const deps = {
      liveness: () => session.liveness(),
      signals: session.signals,
      fetchHerdr: (kind, snap, ids) => session.fetchHerdr(kind, snap, ids),
      gitAhead,
      gitUnlanded: {},
      remote: null,
      inflight: { from: null, to: null },
      remoteAhead: (base) => session.remoteAhead(base),
      seeds: session.seeds,
      counters: session.counters,
    };
    const onSnapshot = (snap) => session.noteTaskIds(snap);
    const wantRemote = steps.some((s) => s.parsed.atoms.some((a) => REMOTE_ATOMS.includes(a.name)));
    let since = await session.baseline(wantRemote);
    const ctxNow = () => ({ since, seeds: session.seeds, seenTaskIds: session.seenTaskIds });
    const timed = (i) => {
      for (let j = i; j < steps.length && (j === i || steps[j].say === ''); j++) {
        if (steps[j].parsed.atoms.some((a) => a.name === 'turn.ended')) return true;
      }
      return false;
    };
    const short = (text) => JSON.stringify(text.length > 60 ? `${text.slice(0, 57)}...` : text);
    const emptyHeldBefore = new Map();
    const noteEmptyWaiters = async (from, ctx) => {
      for (let j = from + 1; j < steps.length && steps[j].say === ''; j++) {
        emptyHeldBefore.set(j, (await holdsNow({ home: session.home, parsed: steps[j].parsed, ctx, deps, onSnapshot })).ok);
      }
    };

    await noteEmptyWaiters(-1, ctxNow());
    result.readyMs = await session.launch();
    log(`primary ready in ${result.readyMs} ms (pid ${session.primaryPid}, lock ${session.lockAtReady})`);

    let allOk = true;
    let firstSay = true;
    for (const [i, step] of steps.entries()) {
      const rec = { say: step.say, until: step.until, ms: 0, ok: false, reason: '' };
      result.steps.push(rec);
      const heldBefore = async () => {
        since = await session.baseline(wantRemote);
        const ctx = ctxNow();
        const pre = await holdsNow({ home: session.home, parsed: step.parsed, ctx, deps, onSnapshot });
        if (pre.ok) return `vacuous: ${step.until} already held before its say, so this step proves nothing`;
        await noteEmptyWaiters(i, ctx);
        return null;
      };
      let withheld = null;
      if (step.say === '' && emptyHeldBefore.get(i)) {
        withheld = `vacuous: ${step.until} already held before the say it waits on, so this step proves nothing`;
      } else if (step.say === RELAUNCH) {
        withheld = await heldBefore();
        if (!withheld) {
          rec.relaunchMs = await session.relaunch();
          log(`step ${i + 1}: relaunched in ${rec.relaunchMs} ms; waiting for ${step.until}`);
        }
      } else if (step.say !== '') {
        if (firstSay) {
          const op = await session.sayWhenOperable(step.say, heldBefore);
          withheld = op.withheld;
          rec.sayMs = op.sayMs;
          result.operableMs = op.operableMs;
          result.readyMs += op.operableMs;
          firstSay = false;
          if (!withheld) log(`home operable in ${op.operableMs} ms; said ${short(step.say)}; waiting for ${step.until}`);
        } else {
          if (timed(i)) {
            const rest = await session.awaitRest(REST_BEFORE_SAY_MS);
            rec.restMs = rest.waitedMs;
            if (!rest.ok) withheld = `the primary never came to rest within ${Math.round(REST_BEFORE_SAY_MS / 1000)} s before the say, so turn.ended could not be timed from it`;
          }
          withheld ??= await heldBefore();
          if (!withheld) {
            rec.sayMs = await session.say(step.say);
            log(`step ${i + 1}: said ${short(step.say)}; waiting for ${step.until}`);
          }
        }
      } else {
        if (firstSay && result.operableMs == null) {
          const op = await session.sayWhenOperable('');
          result.operableMs = op.operableMs;
          result.readyMs += op.operableMs;
          firstSay = false;
        }
        log(`step ${i + 1}: waiting for ${step.until}`);
      }
      if (withheld) {
        rec.vacuous = true;
        rec.reason = withheld;
        allOk = false;
        log(`step ${i + 1}: FAILED (${withheld})`);
        await session.snapshotAll(`step${i + 1}-vacuous`);
        break;
      }
      const budgetMs = Math.round(step.budgetSec * 1000);
      const r = await waitUntil({ home: session.home, parsed: step.parsed, ctx: ctxNow(), budgetMs, deps, onSnapshot });
      rec.ms = r.ms;
      rec.ok = r.ok;
      rec.reason = r.reason;
      result.predicateMs += r.ms;
      log(`step ${i + 1}: ${r.ok ? 'holds' : 'FAILED'} after ${r.ms} ms (${r.reason})`);
      if (!r.ok) {
        allOk = false;
        rec.primaryStatus = await session.primaryStatus();
        rec.tasks = r.snap ? r.snap.taskIds : [];
        await session.snapshotAll(`step${i + 1}-failed`, r.snap);
        break;
      }
    }
    result.pass = allOk && result.steps.length === steps.length && result.steps.at(-1).ok;
    if (result.pass) {
      // The last claim can hold while the primary is still finishing its cleanup, so the home is
      // judged only after the primary has rested and its records have had time to settle.
      const rest = await session.awaitRest(REST_BEFORE_SAY_MS);
      const h = rest.ok
        ? await waitUntil({ home: session.home, parsed: parseUntil(HEALTH), ctx: ctxNow(), budgetMs: Number.parseInt(env.FM_DRIVE_HEALTH_MS || '60000', 10), deps, onSnapshot })
        : { ok: false, reason: `the primary never came to rest within ${Math.round(REST_BEFORE_SAY_MS / 1000)} s after the last step`, ms: 0 };
      result.health = { until: HEALTH, ok: h.ok, reason: h.reason, restMs: rest.waitedMs, ms: h.ms };
      log(`health: ${h.ok ? 'clean' : `MISSED (${h.reason})`}`);
    }
    exitCode = result.pass ? 0 : 1;
  } catch (err) {
    if (err instanceof TraceError) {
      result.rejected = err.message;
      process.stderr.write(`fm-drive: trace rejected: ${err.message}\n`);
    } else {
      result.error = err.message;
      log(`run failed: ${err.message}`);
    }
    exitCode = err instanceof HerdrError || err instanceof TraceError ? err.exitCode : 3;
  } finally {
    if (recheckAtClose) {
      const { hooks, captainMd } = await session.fidelity();
      result.fidelityAtClose = { hooks, captainMd };
      const changed = Object.entries(CAPTAIN_PATH_AT_CLOSE).filter(([field, allowed]) => !allowed.includes(result.fidelityAtClose[field]));
      if (changed.length) {
        const why = `the home left the captain path during the run: ${changed.map(([field]) => `fidelityAtClose.${field} is ${result.fidelityAtClose[field]}`).join(', ')}`;
        log(why);
        result.error = result.error ? `${result.error}; ${why}` : why;
        result.pass = false;
        exitCode = 3;
      }
    }
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
      operableMs: result.operableMs,
      closeMs: result.overhead.closeMs,
    };
    result.spawns = session.spawnTimes();
    result.wallMs = Date.now() - T0;
    if (!result.rejected) {
      try { writeFileSync(join(session.evidenceDir, 'result.json'), `${JSON.stringify(result, null, 2)}\n`); } catch {}
    }
    emit(result);
  }
  return exitCode;
}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (err) => {
    process.stderr.write(`fm-drive: ${err?.stack ?? err}\n`);
    process.exit(3);
  },
);
