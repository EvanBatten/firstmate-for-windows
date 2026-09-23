#!/usr/bin/env node
import { pathToFileURL } from "node:url";
import { interpolateTrace, loadTrace } from "./lib/trace.mjs";
import { evaluateUntil } from "./lib/predicates.mjs";
import { snapshotHome } from "./lib/snapshot.mjs";
import { Session, defaultBudgetSec } from "./lib/session.mjs";

function usage() {
  return "usage: node tools/fm-control/drive.mjs run trace.json";
}

export function parseArgs(argv) {
  if (argv[0] === "run" && argv[1]) return { cmd: "run", tracePath: argv[1] };
  if (argv[0] === "parse" && argv[1]) return { cmd: "parse", tracePath: argv[1] };
  return { error: usage() };
}

function resultShape({ feature, wallMs, pass, readyMs, predicateMs, steps, overhead }) {
  return { feature, wallMs, pass, readyMs, predicateMs, steps, overhead };
}

export async function run(tracePath, opts = {}) {
  const wallStart = Date.now();
  const loaded = loadTrace(tracePath);
  if (loaded.error) {
    const err = new Error(loaded.error);
    err.code = 2;
    throw err;
  }
  let session;
  let readyMs = 0;
  let predicateMs = 0;
  const stepResults = [];
  let lastOk = false;
  try {
    session = opts.session || new Session({ feature: loaded.trace.feature });
    await session.open();
    const trace = interpolateTrace(loaded.trace, {
      projectOrigin: session.projectOrigin,
      home: session.home,
    });
    await session.launchClaude();
    const readyStart = Date.now();
    await session.ready(Number(process.env.FM_CONTROL_READY_MS || 180_000));
    readyMs = Date.now() - wallStart;
    if (!readyMs) readyMs = Date.now() - readyStart;

    for (const step of trace.steps) {
      if (!isNaN(readyMs) && session.readyAtMs) {
        /* readyMs already from process start */
      }
      if (step.say && !step.say.startsWith("$")) {
        await session.say(step.say);
      } else if (step.say) {
        await session.say(step.say);
      }
      const budgetSec = step.budgetSec || defaultBudgetSec(step.until);
      const waited = await session.wait(step.until, budgetSec * 1000);
      predicateMs += waited.ms;
      const snap = snapshotHome(session.home, session.stamps());
      const ok = evaluateUntil(snap, step.until);
      stepResults.push({ until: step.until, ms: waited.ms, ok });
      lastOk = ok;
      if (waited.dead) {
        lastOk = false;
        stepResults[stepResults.length - 1].ok = false;
        break;
      }
      if (!ok) break;
    }
  } catch (err) {
    if (err.code === 2) throw err;
    lastOk = false;
    if (!stepResults.length) {
      stepResults.push({ until: loaded.trace.steps[0].until, ms: Date.now() - wallStart, ok: false });
    }
    if (!readyMs) readyMs = Date.now() - wallStart;
  } finally {
    if (session) await session.close();
  }
  const overhead = session
    ? { herdrCalls: session.herdr.herdrCalls, spawns: session.herdr.spawns }
    : { herdrCalls: 0, spawns: 0 };
  const last = stepResults[stepResults.length - 1];
  const pass = Boolean(last && last.ok && lastOk);
  return resultShape({
    feature: loaded.trace.feature,
    wallMs: Date.now() - wallStart,
    pass,
    readyMs,
    predicateMs,
    steps: stepResults,
    overhead,
  });
}

export async function main(argv = process.argv.slice(2)) {
  const parsed = parseArgs(argv);
  if (parsed.error) {
    process.stderr.write(parsed.error + "\n");
    return 2;
  }
  const loaded = loadTrace(parsed.tracePath);
  if (loaded.error) {
    process.stderr.write(loaded.error + "\n");
    return 2;
  }
  if (parsed.cmd === "parse") {
    process.stdout.write(JSON.stringify({ feature: loaded.trace.feature, steps: loaded.trace.steps.length }) + "\n");
    return 0;
  }
  try {
    const result = await run(parsed.tracePath);
    process.stdout.write(JSON.stringify(result) + "\n");
    return 0;
  } catch (err) {
    if (err.code === 2) {
      process.stderr.write(err.message + "\n");
      return 2;
    }
    process.stderr.write((err && err.message) || String(err) + "\n");
    return 1;
  }
}

const invoked = process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url;
if (invoked) {
  main().then((code) => process.exit(code));
}
