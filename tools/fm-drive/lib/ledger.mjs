// The one definition of proof: which inventory rows a drive result proves,
// and how record rewrites .agents/skills/verify-firstmate/behaviors.tsv from it.

import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { isDeepStrictEqual } from 'node:util';

const BEHAVIORS = join('.agents', 'skills', 'verify-firstmate', 'behaviors.tsv');
const TRACES = join('tools', 'fm-drive', 'traces');
const TRUNK = 'origin/main';
const STATUSES = ['proven', 'unproven', 'broken', 'blocked-here'];

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

// A result proves something only when a pushed commit reproduces the run.
function refuseResult(r, root, heads) {
  if (r === null || typeof r !== 'object' || Array.isArray(r)) return 'the result is not a JSON object';
  if (r.rejected) return `the trace was rejected (${r.rejected}), so no run happened`;
  if (r.error) return `the run failed in its environment (${r.error}), so it proves nothing either way`;
  if (!Array.isArray(r.steps)) return 'the result has no steps';
  if (r.pass !== true) {
    const miss = r.steps.findIndex((s) => !s.ok);
    return miss < 0 ? 'the run did not pass, and a failed run proves nothing' : `the run missed step ${miss + 1} (${r.steps[miss].reason}), and a failed run proves nothing`;
  }
  if (r.health?.ok !== true) return `the run's home health check ${r.health ? `missed (${r.health.reason})` : 'never ran'}, so it proves nothing`;
  if (typeof r.trace !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(r.trace)) return 'the result names no trace';
  if (!r.proves || typeof r.proves !== 'object' || Object.keys(r.proves).length === 0) {
    return `the result names no rows it proves; add proves to trace ${r.trace} and run it again`;
  }
  if (Object.values(r.proves).some((k) => !Number.isInteger(k) || k < 1 || k > r.steps.length)) return 'the result proves a row at a step the run did not take';
  const tracePath = join(root, TRACES, `${r.trace}.json`);
  let shipped;
  try { shipped = JSON.parse(readFileSync(tracePath, 'utf8')).proves; } catch { shipped = undefined; }
  if (!shipped || !isDeepStrictEqual(shipped, r.proves)) {
    return `the result's proves do not match tools/fm-drive/traces/${r.trace}.json, so inventory.sh check could not trace its rows`;
  }
  if (typeof r.evidence !== 'string' || r.evidence === '') return 'the result names no evidence directory';
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
