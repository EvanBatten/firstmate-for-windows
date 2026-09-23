#!/usr/bin/env node
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { loadTrace, TraceError } from "./lib/trace.mjs";
import { Session } from "./lib/session.mjs";

function resultShape(feature, startedAt, readyMs, readyAt, pass, steps, metrics) {
  return {
    feature,
    wallMs: Date.now() - startedAt,
    pass,
    readyMs,
    predicateMs: readyAt === null ? 0 : Date.now() - readyAt,
    steps,
    overhead: { herdrCalls: metrics.herdrCalls, spawns: metrics.spawns },
  };
}

export async function run(tracePath, environment = process.env) {
  const trace = loadTrace(tracePath);
  const startedAt = Date.now();
  const metrics = { herdrCalls: 0, spawns: 0 };
  const session = new Session({ trace, environment, metrics });
  const stepResults = [];
  let pass = false;
  let runtimeError = null;
  try {
    await session.open(startedAt);
    for (const step of session.trace.steps) {
      const stepStarted = Date.now();
      try {
        await session.performSay(step.say);
        const outcome = await session.wait(step);
        stepResults.push({
          until: step.until,
          ms: Date.now() - stepStarted,
          ok: outcome.ok === true,
          ...(outcome.reason ? { reason: outcome.reason } : {}),
        });
        if (!outcome.ok) break;
      } catch (error) {
        stepResults.push({
          until: step.until,
          ms: Date.now() - stepStarted,
          ok: false,
          reason: error.message,
        });
        runtimeError = error;
        break;
      }
    }
    pass = stepResults.length === session.trace.steps.length &&
      stepResults.at(-1)?.ok === true;
  } catch (error) {
    runtimeError = error;
  } finally {
    await session.close();
  }
  const result = resultShape(
    trace.feature,
    startedAt,
    session.readyMs,
    session.readyAt,
    pass,
    stepResults,
    metrics,
  );
  return { result, runtimeError };
}

export async function main(argv = process.argv.slice(2), environment = process.env) {
  if (argv.length !== 2 || argv[0] !== "run") {
    process.stderr.write("usage: node tools/fm-control/drive.mjs run <trace.json>\n");
    return 2;
  }
  let outcome;
  try {
    outcome = await run(resolve(argv[1]), environment);
  } catch (error) {
    const prefix = error instanceof TraceError ? "trace rejected" : "driver failed";
    process.stderr.write(`${prefix}: ${error.message}\n`);
    return error instanceof TraceError ? 2 : 3;
  }
  process.stdout.write(`${JSON.stringify(outcome.result)}\n`);
  if (outcome.runtimeError) {
    process.stderr.write(`run failed: ${outcome.runtimeError.message}\n`);
  }
  return outcome.result.pass ? 0 : 1;
}

const invoked = process.argv[1] &&
  resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (invoked) {
  process.exitCode = await main();
}
