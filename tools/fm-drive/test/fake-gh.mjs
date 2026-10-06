import { spawnSync } from 'node:child_process';

// Answers `gh pr list ... --json number,mergeCommit,headRefOid` for the bare repo in
// FM_DRIVE_REMOTE_ORIGIN. FAKE_GH_MODE=merged reports main's tip as a forge merge commit,
// pushed reports it as a pull request whose head was pushed straight to main, and anything else
// reports no merged pull request.
const args = process.argv.slice(2);
if (args[0] !== 'pr' || args[1] !== 'list') {
  process.stderr.write(`fake gh has no answer for ${args.join(' ')}\n`);
  process.exit(2);
}
const main = spawnSync('git', ['-C', process.env.FM_DRIVE_REMOTE_ORIGIN, 'rev-parse', 'main'], { encoding: 'utf8' }).stdout.trim();
const mode = process.env.FAKE_GH_MODE;
const prs = mode === 'merged'
  ? [{ number: 7, mergeCommit: { oid: main }, headRefOid: 'f'.repeat(40) }]
  : mode === 'pushed' ? [{ number: 7, mergeCommit: { oid: main }, headRefOid: main }] : [];
process.stdout.write(`${JSON.stringify(prs)}\n`);
