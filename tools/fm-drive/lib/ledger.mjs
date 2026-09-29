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

// Per row, its last proving step k decides:
//   held       every step 1..k held and the run's health held
//   health     every step 1..k held but the health check missed
//   missed     step i <= k ran and did not hold
//   unchecked  steps 1..k held or never ran, but the run failed later, so
//              health was never checked and the row proves nothing
function rowVerdicts(proves, result) {
  const verdicts = {};
  for (const [id, k] of Object.entries(proves)) {
    const upTo = result.steps.slice(0, k);
    const miss = upTo.findIndex((s) => !s.ok);
    if (miss >= 0) verdicts[id] = { kind: 'missed', step: miss + 1, reason: upTo[miss].reason };
    else if (upTo.length < k || !result.health) verdicts[id] = { kind: 'unchecked' };
    else if (result.health.ok) verdicts[id] = { kind: 'held', step: k };
    else verdicts[id] = { kind: 'health', reason: result.health.reason };
  }
  return verdicts;
}

const cell = (text) => String(text).replace(/[\t\r\n]+/g, ' ');

function nextRow(row, verdict, run) {
  const note = (what) => cell(`${run.sha} ${what}; ${run.evidence}`);
  switch (verdict.kind) {
    case 'held':
      return { status: 'proven', ref: run.trace, evidence: note(`held through step ${verdict.step}, health clean`) };
    case 'missed': {
      const evidence = note(`missed step ${verdict.step}: ${verdict.reason}`);
      if (row.status === 'proven' || row.status === 'broken') return { status: 'broken', ref: run.trace, evidence };
      if (row.status === 'unproven') return { ...row, evidence };
      return null;
    }
    case 'health':
      return row.status === 'unproven' ? { ...row, evidence: note(`held every step but health missed: ${verdict.reason}`) } : null;
    default:
      return null;
  }
}

function applyVerdicts(text, verdicts, run) {
  const lines = text.split('\n');
  const changes = [];
  const seen = new Set();
  for (let i = 1; i < lines.length; i++) {
    if (lines[i] === '') continue;
    const cols = lines[i].split('\t');
    const id = cols[0];
    if (!(id in verdicts)) continue;
    seen.add(id);
    const row = { status: cols[3], ref: cols[4], evidence: cols[5] ?? '' };
    const next = nextRow(row, verdicts[id], run);
    if (!next) continue;
    if (next.status !== row.status) changes.push(`${id}: ${row.status} -> ${next.status}`);
    lines[i] = [...cols.slice(0, 3), next.status, next.ref, next.evidence].join('\t');
  }
  const unknown = Object.keys(verdicts).filter((id) => !seen.has(id));
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
  if (typeof r.trace !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(r.trace)) return 'the result names no trace';
  if (!r.proves || typeof r.proves !== 'object' || Object.keys(r.proves).length === 0) {
    return `the result names no rows it proves; add proves to trace ${r.trace} and run it again`;
  }
  if (Object.values(r.proves).some((k) => !Number.isInteger(k) || k < 1)) return 'the result proves a row at a step that is not a positive step number';
  const tracePath = join(root, TRACES, `${r.trace}.json`);
  let shipped;
  try { shipped = JSON.parse(readFileSync(tracePath, 'utf8')).proves; } catch { shipped = undefined; }
  if (!shipped || !isDeepStrictEqual(shipped, r.proves)) {
    return `the result's proves do not match tools/fm-drive/traces/${r.trace}.json, so inventory.sh check could not trace its rows`;
  }
  if (!Array.isArray(r.steps)) return 'the result has no steps';
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
  const { text, changes, unknown } = applyVerdicts(before, rowVerdicts(result.proves, result), run);
  if (unknown.length) return { refused: `the run claims ${unknown.join(', ')}, which behaviors.tsv has no row for` };
  if (text !== before) writeFileSync(path, text);
  return { lines: [...changes, tally(text)] };
}
