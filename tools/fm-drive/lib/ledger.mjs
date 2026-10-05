import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { isDeepStrictEqual } from 'node:util';

const BEHAVIORS = join('.agents', 'skills', 'verify-firstmate', 'behaviors.tsv');
const TRACES = 'tools/fm-drive/traces';
const TRUNK = 'origin/main';
const STATUSES = ['proven', 'unproven', 'broken', 'blocked-here'];

// waitUntil's last look fires when the deadline timer does, so a step that
// held on that look reports a little over its budget.
const LAST_LOOK_GRACE_MS = 2000;

const cell = (text) => String(text).replace(/[\t\r\n]+/g, ' ');

function applyProof(text, proves, run) {
  const lines = text.split('\n');
  const changes = [];
  const seen = new Set();
  for (let i = 1; i < lines.length; i++) {
    if (lines[i] === '') continue;
    const cols = lines[i].split('\t');
    const id = cols[0];
    if (!(id in proves)) continue;
    seen.add(id);
    if (cols[3] !== 'proven') changes.push(`${id}: ${cols[3]} -> proven`);
    const evidence = cell(`${run.sha} held through step ${proves[id]}, health clean; ${run.evidence}`);
    lines[i] = [...cols.slice(0, 3), 'proven', run.trace, evidence].join('\t');
  }
  const unknown = Object.keys(proves).filter((id) => !seen.has(id));
  return { text: lines.join('\n'), changes, unknown };
}

function tally(text) {
  const counts = Object.fromEntries(STATUSES.map((s) => [s, 0]));
  const rows = text.split('\n').slice(1).filter((l) => l !== '');
  for (const l of rows) {
    const status = l.split('\t')[3];
    if (status in counts) counts[status] += 1;
  }
  return `proven ${counts.proven} of ${rows.length} behaviors; ${counts.unproven} unproven; ${counts.broken} broken; ${counts['blocked-here']} blocked here`;
}

function git(root, args) {
  return spawnSync('git', ['-C', root, ...args], { encoding: 'utf8', shell: false, windowsHide: true });
}

// A result proves something only when a pushed commit reproduces the run,
// so it is checked against the trace as that commit has it.
function refuseResult(r, root, heads) {
  if (r === null || typeof r !== 'object' || Array.isArray(r)) return 'the result is not a JSON object';
  if (r.rejected) return `the trace was rejected (${r.rejected}), so no run happened`;
  if (r.error) return `the run failed in its environment (${r.error}), so it proves nothing either way`;
  if (typeof r.trace !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(r.trace)) return 'the result names no trace';
  if (!r.proves || typeof r.proves !== 'object' || Object.keys(r.proves).length === 0) {
    return `the result names no rows it proves; add proves to trace ${r.trace} and run it again`;
  }
  const sha = r.code?.sha;
  if (typeof sha !== 'string' || !/^[0-9a-f]{40}$/.test(sha)) return 'the result names no commit it drove';
  if (r.code.dirty !== false) return `the run drove ${sha} with uncommitted changes, which no commit can reproduce`;
  for (const head of heads) {
    if (git(root, ['rev-parse', '--verify', '--quiet', `refs/remotes/${head}`]).status !== 0) {
      return `--head ${head} is not a remote-tracking ref such as origin/<branch>`;
    }
  }
  const reachable = [TRUNK, ...heads].some((ref) => git(root, ['merge-base', '--is-ancestor', sha, `refs/remotes/${ref}`]).status === 0);
  if (!reachable) {
    const from = [TRUNK, ...heads].join(' or ');
    return `${sha} is not reachable from ${from}; push it and name its branch with --head origin/<branch>`;
  }
  const tracePath = `${TRACES}/${r.trace}.json`;
  const shown = git(root, ['show', `${sha}:${tracePath}`]);
  let trace;
  try { trace = shown.status === 0 ? JSON.parse(shown.stdout) : null; } catch { trace = null; }
  if (!trace?.proves || !isDeepStrictEqual(trace.proves, r.proves)) {
    return `the result's proves do not match ${tracePath} at ${sha}, so inventory.sh check could not trace its rows`;
  }
  if (!Array.isArray(r.steps)) return 'the result has no steps';
  const miss = r.steps.findIndex((s) => s?.ok !== true);
  if (miss >= 0) return `the run missed step ${miss + 1} (${r.steps[miss]?.reason}), and a failed run proves nothing`;
  if (r.pass !== true) return 'the run did not pass, and a failed run proves nothing';
  const want = Array.isArray(trace.steps) ? trace.steps : [];
  if (r.steps.length !== want.length) return `the result has ${r.steps.length} steps but trace ${r.trace} has ${want.length}`;
  const differs = r.steps.findIndex((s, i) => s.until !== String(want[i]?.until).trim());
  if (differs >= 0) return `step ${differs + 1} waited on ${r.steps[differs].until} but trace ${r.trace} waits on ${String(want[differs]?.until).trim()}`;
  const untimed = r.steps.findIndex((s) => !(Number.isFinite(s.ms) && s.ms >= 0));
  if (untimed >= 0) return `step ${untimed + 1} has no elapsed time (ms is ${'ms' in r.steps[untimed] ? JSON.stringify(r.steps[untimed].ms) : 'missing'})`;
  const late = r.steps.findIndex((s, i) => typeof want[i].budgetSec === 'number' && s.ms > want[i].budgetSec * 1000 + LAST_LOOK_GRACE_MS);
  if (late >= 0) return `step ${late + 1} took ${r.steps[late].ms} ms, over its ${want[late].budgetSec} s budget in trace ${r.trace}`;
  if (r.health?.ok !== true) return `the run's home health check ${r.health ? `missed (${r.health.reason})` : 'never ran'}, so it proves nothing`;
  if (Object.values(r.proves).some((k) => !Number.isInteger(k) || k < 1 || k > r.steps.length)) return 'the result proves a row at a step the run did not take';
  if (typeof r.evidence !== 'string' || r.evidence === '') return 'the result names no evidence directory';
  return null;
}

export function record({ resultPath, root, heads = [] }) {
  let result;
  try {
    result = JSON.parse(readFileSync(resultPath, 'utf8'));
  } catch (err) {
    return { refused: `cannot read the result ${resultPath}: ${err.message}` };
  }
  const refused = refuseResult(result, root, heads);
  if (refused) return { refused };

  const path = join(root, BEHAVIORS);
  const before = readFileSync(path, 'utf8');
  const run = { sha: result.code.sha, trace: result.trace, evidence: result.evidence };
  const { text, changes, unknown } = applyProof(before, result.proves, run);
  if (unknown.length) return { refused: `the run claims ${unknown.join(', ')}, which behaviors.tsv has no row for` };
  if (text !== before) writeFileSync(path, text);
  return { lines: [...changes, tally(text)] };
}
