import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const DRIVE = join(HERE, '..', 'drive.mjs');
const RESULTS = join(HERE, 'fixtures', 'results');
const REPO = join(HERE, '..', '..', '..');
const INVENTORY = join(REPO, '.agents', 'skills', 'verify-firstmate', 'inventory.sh');
const TSV_REL = join('.agents', 'skills', 'verify-firstmate', 'behaviors.tsv');
const NODE = process.execPath;

const scratch = [];
function tmp(prefix) {
  const d = mkdtempSync(join(tmpdir(), `fm-drive-ledger-${prefix}-`));
  scratch.push(d);
  return d;
}
after(() => { for (const d of scratch) rmSync(d, { recursive: true, force: true }); });

function git(root, ...args) {
  const r = spawnSync('git', ['-C', root, '-c', 'user.email=t@example.invalid', '-c', 'user.name=t', ...args], { encoding: 'utf8' });
  assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
}

const HEADER = 'id\tsource\tbehavior\tstatus\tref\tevidence';
const row = (id, status, ref, evidence) => `${id}\treadme:features\tthe ${id} behavior\t${status}\t${ref}\t${evidence}`;
const tsv = (...rows) => `${[HEADER, ...rows].join('\n')}\n`;

const BASE = tsv(
  row('row-register', 'unproven', '#83', 'not yet re-proven on main'),
  row('row-dispatch', 'unproven', '#83', ''),
  row('row-other', 'unproven', '#84', 'untouched'),
  row('row-blocked', 'blocked-here', '#97', 'machine: no tmux here'),
);

// A checkout whose main is pushed to a bare origin, so record can ask
// whether a result's commit is reachable from origin/main.
const PROVES = { 'row-register': 1, 'row-dispatch': 2 };

function ledgerRepo(behaviors, proves = PROVES) {
  const root = tmp('root');
  const origin = tmp('origin');
  git(origin, 'init', '-q', '--bare', '-b', 'main');
  git(root, 'init', '-q', '-b', 'main');
  writeFileSync(join(root, '.gitattributes'), '* text=auto eol=lf\n');
  mkdirSync(dirname(join(root, TSV_REL)), { recursive: true });
  writeFileSync(join(root, TSV_REL), behaviors);
  mkdirSync(join(root, 'tools', 'fm-drive', 'traces'), { recursive: true });
  writeFileSync(join(root, 'tools', 'fm-drive', 'traces', 'register.json'), JSON.stringify({ feature: 'register', steps: [], proves }));
  git(root, 'add', '-A');
  git(root, 'commit', '-qm', 'inventory');
  git(root, 'remote', 'add', 'origin', origin);
  git(root, 'push', '-q', 'origin', 'main');
  git(root, 'fetch', '-q', 'origin');
  return { root, sha: git(root, 'rev-parse', 'HEAD') };
}

function resultFile(name, sha, edit = (r) => r) {
  const raw = JSON.parse(readFileSync(join(RESULTS, `${name}.json`), 'utf8').replaceAll('{{sha}}', sha));
  const p = join(tmp('result'), 'result.json');
  writeFileSync(p, JSON.stringify(edit(raw)));
  return p;
}

function record(root, resultPath, ...extra) {
  const r = spawnSync(NODE, [DRIVE, 'record', resultPath, ...extra], { env: { ...process.env, FM_DRIVE_ROOT: root }, encoding: 'utf8', timeout: 60_000 });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr, tsv: readFileSync(join(root, TSV_REL), 'utf8') };
}

describe('record', () => {
  test('a run that held flips each row it proves to proven with the run as evidence', () => {
    const { root, sha } = ledgerRepo(BASE);
    const r = record(root, resultFile('held', sha));
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.tsv, tsv(
      row('row-register', 'proven', 'register', `${sha} held through step 1, health clean; /tmp/fm-drive-artifacts/register-20260929T120000Z`),
      row('row-dispatch', 'proven', 'register', `${sha} held through step 2, health clean; /tmp/fm-drive-artifacts/register-20260929T120000Z`),
      row('row-other', 'unproven', '#84', 'untouched'),
      row('row-blocked', 'blocked-here', '#97', 'machine: no tmux here'),
    ));
    assert.equal(r.stdout, [
      'row-register: unproven -> proven',
      'row-dispatch: unproven -> proven',
      'proven 2 of 4 behaviors; 1 unproven; 0 broken; 1 blocked here',
      '',
    ].join('\n'));
  });

  test('recording the same result twice leaves the table byte for byte unchanged', () => {
    const { root, sha } = ledgerRepo(BASE);
    const result = resultFile('held', sha);
    const first = record(root, result);
    assert.equal(first.status, 0, first.stderr);
    const second = record(root, result);
    assert.equal(second.status, 0, second.stderr);
    assert.equal(second.tsv, first.tsv);
    assert.equal(second.stdout, 'proven 2 of 4 behaviors; 1 unproven; 0 broken; 1 blocked here\n');
  });

  test('a failed run is refused and leaves every row as it was, proven or not', () => {
    const table = tsv(
      row('row-register', 'proven', 'register', 'abc held through step 1, health clean; /tmp/old'),
      row('row-dispatch', 'unproven', '#83', ''),
    );
    const { root, sha } = ledgerRepo(table);
    const r = record(root, resultFile('missed-step-2', sha));
    assert.equal(r.status, 2);
    assert.equal(r.stderr, 'fm-drive: record refused: the run missed step 2 (tasks.count>=1: 0 task records), and a failed run proves nothing\n');
    assert.equal(r.tsv, table);
  });

  test('a run whose health check missed is refused and the table is untouched', () => {
    const { root, sha } = ledgerRepo(BASE);
    const r = record(root, resultFile('health-missed', sha));
    assert.equal(r.status, 2);
    assert.equal(r.stderr, "fm-drive: record refused: the run's home health check missed (home.clean: task records remain: greeter-cli-g1), so it proves nothing\n");
    assert.equal(r.tsv, BASE);
  });

  test('an environment error is refused and the table is untouched', () => {
    const { root, sha } = ledgerRepo(BASE);
    const r = record(root, resultFile('env-error', sha));
    assert.equal(r.status, 2);
    assert.equal(r.stderr, 'fm-drive: record refused: the run failed in its environment (herdr: no server answered on the socket), so it proves nothing either way\n');
    assert.equal(r.tsv, BASE);
  });

  test('a result from a dirty tree is refused and the table is untouched', () => {
    const { root, sha } = ledgerRepo(BASE);
    const r = record(root, resultFile('dirty', sha));
    assert.equal(r.status, 2);
    assert.equal(r.stderr, `fm-drive: record refused: the run drove ${sha} with uncommitted changes, which no commit can reproduce\n`);
    assert.equal(r.tsv, BASE);
  });

  test('a result from an unpushed commit is refused until a named remote head carries it', () => {
    const { root } = ledgerRepo(BASE);
    writeFileSync(join(root, 'feature.txt'), 'x\n');
    git(root, 'add', '-A');
    git(root, 'commit', '-qm', 'unpushed');
    const sha = git(root, 'rev-parse', 'HEAD');
    const result = resultFile('held', sha);
    const refused = record(root, result);
    assert.equal(refused.status, 2);
    assert.equal(refused.stderr, `fm-drive: record refused: ${sha} is not reachable from origin/main; push it and name its branch with --head origin/<branch>\n`);
    assert.equal(refused.tsv, BASE);

    const notRemote = record(root, result, '--head', 'main');
    assert.equal(notRemote.status, 2);
    assert.equal(notRemote.stderr, 'fm-drive: record refused: --head main is not a remote-tracking ref such as origin/<branch>\n');

    git(root, 'push', '-q', 'origin', 'HEAD:refs/heads/direct/x');
    git(root, 'fetch', '-q', 'origin');
    const pushed = record(root, result, '--head', 'origin/direct/x');
    assert.equal(pushed.status, 0, pushed.stderr);
    assert.match(pushed.tsv, new RegExp(`^row-register\\t[^\\t]*\\t[^\\t]*\\tproven\\tregister\\t${sha} held through step 1`, 'm'));
  });

  test('a result that claims a row the table does not have is refused', () => {
    const { root, sha } = ledgerRepo(BASE, { ...PROVES, 'row-typo': 1 });
    const r = record(root, resultFile('held', sha, (res) => ({ ...res, proves: { ...res.proves, 'row-typo': 1 } })));
    assert.equal(r.status, 2);
    assert.equal(r.stderr, 'fm-drive: record refused: the run claims row-typo, which behaviors.tsv has no row for\n');
    assert.equal(r.tsv, BASE);
  });

  test('a result whose proves differ from the committed trace is refused', () => {
    const { root, sha } = ledgerRepo(BASE, { 'row-register': 1 });
    const r = record(root, resultFile('held', sha));
    assert.equal(r.status, 2);
    assert.equal(r.stderr, "fm-drive: record refused: the result's proves do not match tools/fm-drive/traces/register.json, so inventory.sh check could not trace its rows\n");
    assert.equal(r.tsv, BASE);
  });

  test('a result from a trace that proves no row is refused', () => {
    const { root, sha } = ledgerRepo(BASE);
    const r = record(root, resultFile('held', sha, ({ proves, ...rest }) => rest));
    assert.equal(r.status, 2);
    assert.equal(r.stderr, 'fm-drive: record refused: the result names no rows it proves; add proves to trace register and run it again\n');
    assert.equal(r.tsv, BASE);
  });
});

function inventoryTree(behaviors, trace) {
  const root = tmp('inv');
  const skill = join(root, '.agents', 'skills', 'verify-firstmate');
  mkdirSync(join(skill, 'features'), { recursive: true });
  copyFileSync(INVENTORY, join(skill, 'inventory.sh'));
  writeFileSync(join(skill, 'behaviors.tsv'), behaviors);
  mkdirSync(join(root, 'tests', 'verification'), { recursive: true });
  writeFileSync(join(root, 'tests', 'verification', 'coverage.tsv'), 'script\tkind\n');
  writeFileSync(join(root, 'README.md'), '# t\n\n## Features\n\n- one\n');
  mkdirSync(join(root, 'tools', 'fm-drive', 'traces'), { recursive: true });
  writeFileSync(join(root, 'tools', 'fm-drive', 'traces', 'register.json'), JSON.stringify(trace));
  git(root, 'init', '-q', '-b', 'main');
  return join(skill, 'inventory.sh');
}

const registerTrace = (proves) => ({ feature: 'register', steps: [{ say: 'ahoy', until: 'projects.registered:greeter' }], proves });
const inventory = (script, ...args) => spawnSync('bash', [script, ...args], { encoding: 'utf8', timeout: 60_000 });

describe('inventory.sh with trace refs', () => {
  test('check accepts a proven row whose trace lists it', () => {
    const script = inventoryTree(tsv(row('row-register', 'proven', 'register', 'sha held')), registerTrace({ 'row-register': 1 }));
    const r = inventory(script, 'check');
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.equal(r.stdout, 'ok - inventory: 1 behaviors, 1 proven, 0 unproven, 0 broken, 0 blocked here\n');
  });

  test('check refuses a proven row whose trace does not list it', () => {
    const script = inventoryTree(tsv(row('row-register', 'proven', 'register', 'sha held')), registerTrace({ 'row-dispatch': 1 }));
    const r = inventory(script, 'check');
    assert.equal(r.status, 1);
    assert.match(r.stdout, /^not ok - row 'row-register' is proven but ref 'register' names no tests\/verification\/register\.verify\.sh and no tools\/fm-drive\/traces\/register\.json that proves it$/m);
  });

  test('verdict counts a trace-proven row as proven by its recorded run', () => {
    const script = inventoryTree(tsv(row('row-register', 'proven', 'register', 'sha held')), registerTrace({ 'row-register': 1 }));
    const log = join(tmp('log'), 'run.log');
    writeFileSync(log, 'result: other passed\n');
    const r = inventory(script, 'verdict', log);
    assert.equal(r.stdout, 'proven 1 of 1 behaviors; 0 unproven; 0 broken; 0 blocked here\n');
  });

  test('the shipped inventory passes check', () => {
    const r = inventory(INVENTORY, 'check');
    assert.equal(r.status, 0, r.stdout.split('\n').filter((l) => l.startsWith('not ok')).join('\n'));
  });
});
