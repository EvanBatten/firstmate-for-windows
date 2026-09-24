// Behavioral tests for the fm-control driver. Run with:
//   node --test tools/fm-control/test/
// No real herdr or claude is involved: fake-herdr.mjs stands in for the
// binary through the driver's cli transport, and every home is a temp dir.

import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync, spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, rmSync, symlinkSync, utimesSync, lstatSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { parseUntil, evaluateUntil, snapshotHome, CATALOG } from '../lib/predicates.mjs';
import { validateTrace, TraceError } from '../lib/trace.mjs';
import { atShellPrompt, cliArgv } from '../lib/herdr.mjs';
import { Session, prepareClaudeConfig, archiveClaudeConfig, isAuthStateKey, isCredentialFileName, homeIsOperable, isSessionStartBusy, isThrowawayControlHome, controlBashPath, prestartThrowawayHome, isTrustPrompt, trustProjectKeys, stripThrowawaySessionStartHooks, throwawayPaneSessionEnv, ensureThrowawayTools } from '../lib/session.mjs';
import { waitUntil } from '../lib/wait.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const DRIVE = join(HERE, '..', 'drive.mjs');
const FAKE = join(HERE, 'fake-herdr.mjs');
const FIXTURES = join(HERE, 'fixtures');
const NODE = process.execPath;

const scratch = [];
function tmp(prefix) {
  const d = mkdtempSync(join(tmpdir(), `fm-control-test-${prefix}-`));
  scratch.push(d);
  return d;
}
after(() => { for (const d of scratch) rmSync(d, { recursive: true, force: true }); });

function buildHome(specName) {
  const spec = JSON.parse(readFileSync(join(FIXTURES, 'homes', `${specName}.json`), 'utf8'));
  const home = tmp(`home-${specName}`);
  for (const d of spec.dirs ?? []) mkdirSync(join(home, d), { recursive: true });
  for (const [rel, content] of Object.entries(spec.files ?? {})) {
    mkdirSync(dirname(join(home, rel)), { recursive: true });
    writeFileSync(join(home, rel), content);
  }
  return home;
}

function fakeEnv(extra = {}) {
  const fakeDir = tmp('fake');
  const fakeHome = tmp('user-home');
  return {
    dir: fakeDir,
    env: {
      ...process.env,
      HOME: fakeHome,
      USERPROFILE: fakeHome,
      CLAUDE_CONFIG_DIR: '',
      FM_CONTROL_HERDR: FAKE,
      FM_CONTROL_TRANSPORT: 'cli',
      FM_CONTROL_QUIET: '1',
      FM_CONTROL_READY_MS: '20000',
      FM_CONTROL_PRESTART: '0',
      FAKE_HERDR_DIR: fakeDir,
      ...extra,
    },
  };
}

function runDrive(args, env) {
  const r = spawnSync(NODE, [DRIVE, ...args], { env, encoding: 'utf8', timeout: 120_000 });
  let json = null;
  try { json = JSON.parse(r.stdout.trim().split('\n').at(-1)); } catch { /* not JSON */ }
  return { status: r.status, stdout: r.stdout, stderr: r.stderr, json };
}

// ---- 1. refusal happens before any herdr call ------------------------------

describe('trace refusal', () => {
  const rejects = readdirSync(join(FIXTURES, 'reject')).filter((f) => f.endsWith('.json'));
  assert.ok(rejects.length >= 10, 'reject fixtures present');
  for (const f of rejects) {
    test(`${f} exits 2 with zero herdr spawns`, () => {
      const { dir, env } = fakeEnv();
      const r = runDrive(['run', join(FIXTURES, 'reject', f)], env);
      assert.equal(r.status, 2, `stderr: ${r.stderr}`);
      assert.equal(r.json?.pass, false);
      assert.equal(typeof r.json?.rejected, 'string');
      assert.ok(!existsSync(join(dir, 'calls.log')), 'the fake herdr was never invoked');
      assert.ok(!existsSync(join(dir, 'state.json')), 'no herdr state was created');
    });
  }

  test('a missing trace file exits 2', () => {
    const { dir, env } = fakeEnv();
    const r = runDrive(['run', join(FIXTURES, 'reject', 'does-not-exist.json')], env);
    assert.equal(r.status, 2);
    assert.ok(!existsSync(join(dir, 'calls.log')));
  });

  test('the shipped traces validate through check', () => {
    for (const name of ['restart-primary', 'scout-report']) {
      const r = runDrive(['check', join(HERE, '..', 'traces', `${name}.json`)], process.env);
      assert.equal(r.status, 0, r.stderr);
      assert.equal(r.json.feature, name);
      assert.ok(r.json.steps.length >= 5);
    }
  });

  test('validateTrace refuses the startup-only shapes in process', () => {
    assert.throws(() => validateTrace({ feature: 'x', steps: [{ say: '', until: 'pong' }] }), TraceError);
    assert.throws(() => validateTrace({ feature: 'x', steps: [{ say: '', until: 'bypass permissions on' }] }), TraceError);
    assert.throws(() => validateTrace({ feature: 'x', steps: [{ say: '', until: 'lock.held' }, { say: '', until: 'lock.held' }] }), TraceError);
    const ok = validateTrace({ feature: 'x', steps: [{ say: '', until: 'lock.held' }, { say: 'go', until: 'tasks.count>=1' }] });
    assert.equal(ok.steps.length, 2);
    assert.equal(ok.steps[1].parsed.atoms[0].name, 'tasks.count');
  });

  test('every catalog entry parses in at least one spelling', () => {
    const samples = ['projects.registered:greeter', 'tasks.count>=1', 'backlog.inflight>=1', 'tasks.kind:scout', 'status.verb:done', 'report.exists', 'report.mentions:greet', 'inbox.handled', 'lock.held', 'lock.rotated', 'git.ahead:greeter>=1', 'home.clean', 'tabs.clean', 'worker.alive', 'wake.empty', 'beacon.fresh', 'file.contains:data/projects.md:greeter'];
    const names = new Set(samples.map((s) => parseUntil(s).atoms[0].name));
    for (const c of CATALOG) assert.ok(names.has(c), `catalog entry ${c} has a sample`);
  });
});

// ---- 2. predicates over fixture homes are literal booleans -----------------

describe('predicates over fixture homes', () => {
  const ctx = (over = {}) => ({ lockBaseline: undefined, seeds: {}, seenTaskIds: new Set(), ...over });
  const check = (home, until, c, snapPatch) => {
    const snap = snapshotHome(home);
    Object.assign(snap, snapPatch ?? {});
    const r = evaluateUntil(parseUntil(until), snap, c ?? ctx());
    assert.equal(typeof r.ok, 'boolean', `${until} yields a boolean`);
    assert.equal(typeof r.reason, 'string');
    return r;
  };

  test('empty home', () => {
    const home = buildHome('empty');
    assert.equal(check(home, 'projects.registered:greeter').ok, false);
    assert.equal(check(home, 'tasks.count>=1').ok, false);
    assert.equal(check(home, 'tasks.count>=0').ok, true);
    assert.equal(check(home, 'home.clean').ok, true);
    assert.equal(check(home, 'wake.empty').ok, true);
    assert.equal(check(home, 'lock.held').ok, false);
    assert.equal(check(home, 'report.exists').ok, false);
    assert.equal(check(home, 'inbox.handled').ok, false);
    assert.equal(check(home, 'status.verb:done').ok, false);
    assert.equal(check(home, 'beacon.fresh').ok, false);
    assert.equal(check(home, 'file.contains:data/projects.md:greeter').ok, false);
    const w = check(home, 'worker.alive');
    assert.equal(w.ok, false);
    assert.equal(w.needs, undefined, 'no recorded pane means no herdr fact is even requested');
  });

  test('ship in flight', () => {
    const home = buildHome('ship-in-flight');
    assert.equal(check(home, 'projects.registered:greeter').ok, true);
    assert.equal(check(home, 'projects.registered:other').ok, false);
    assert.equal(check(home, 'tasks.count>=1').ok, true);
    assert.equal(check(home, 'tasks.count>=2').ok, false);
    assert.equal(check(home, 'backlog.inflight>=1').ok, true);
    assert.equal(check(home, 'backlog.inflight>=2').ok, false, 'the Queued item is not In flight');
    assert.equal(check(home, 'tasks.kind:ship').ok, true);
    assert.equal(check(home, 'tasks.kind:scout').ok, false);
    assert.equal(check(home, 'status.verb:working').ok, true);
    assert.equal(check(home, 'status.verb:note').ok, true);
    assert.equal(check(home, 'status.verb:done').ok, false);
    assert.equal(check(home, 'inbox.handled').ok, true);
    assert.equal(check(home, 'home.clean').ok, false);
    assert.equal(check(home, 'wake.empty').ok, true, 'an empty queue file is empty');
    assert.equal(check(home, 'lock.held').ok, true);
    assert.equal(check(home, 'lock.rotated', ctx({ lockBaseline: '4242' })).ok, false);
    assert.equal(check(home, 'lock.rotated', ctx({ lockBaseline: '1' })).ok, true);
    assert.equal(check(home, 'lock.rotated', ctx({ lockBaseline: null })).ok, true, 'a home that had no lock before now has one');
    assert.equal(check(home, 'lock.rotated', ctx()).ok, false, 'no relaunch happened, so nothing rotated');
    assert.equal(check(home, 'report.exists').ok, false, 'a brief is not a report');
    assert.equal(check(home, 'file.contains:data/projects.md:greeter').ok, true);
    assert.equal(check(home, 'file.contains:data/projects.md:pirate').ok, false);
    assert.equal(check(home, 'projects.registered:greeter && tasks.count>=1 && status.verb:working').ok, true);
    assert.equal(check(home, 'projects.registered:greeter && status.verb:done').ok, false);
  });

  test('git.ahead asks for one git fact, then decides', () => {
    const home = buildHome('ship-in-flight');
    const sha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    assert.equal(check(home, 'git.ahead:greeter>=1', ctx({ seeds: { greeter: sha } })).ok, false, 'main still at the seed');
    const pending = check(home, 'git.ahead:greeter>=1', ctx({ seeds: { greeter: 'a'.repeat(40) } }));
    assert.equal(pending.ok, false);
    assert.equal(pending.needs, 'git');
    assert.equal(check(home, 'git.ahead:greeter>=1', ctx({ seeds: { greeter: 'a'.repeat(40) } }), { gitAhead: { greeter: { sha, count: 1 } } }).ok, true);
    assert.equal(check(home, 'git.ahead:greeter>=2', ctx({ seeds: { greeter: 'a'.repeat(40) } }), { gitAhead: { greeter: { sha, count: 1 } } }).ok, false);
    assert.equal(check(home, 'git.ahead:greeter>=1', ctx({ seeds: { greeter: 'a'.repeat(40) } }), { gitAhead: { greeter: { sha: 'stale', count: 5 } } }).needs, 'git', 'a cached count for another sha is not reused');
    assert.equal(check(home, 'git.ahead:missing>=1').ok, false);
  });

  test('herdr-backed atoms request their fact and then decide', () => {
    const home = buildHome('ship-in-flight');
    const c = ctx({ seenTaskIds: new Set(['t1']) });
    const t = check(home, 'tabs.clean', c);
    assert.equal(t.ok, false);
    assert.equal(t.needs, 'tabs');
    assert.equal(check(home, 'tabs.clean', c, { herdr: { tabLabels: ['fm-t1', 'other'] } }).ok, false);
    assert.equal(check(home, 'tabs.clean', c, { herdr: { tabLabels: ['other'] } }).ok, true);
    const w = check(home, 'worker.alive', c);
    assert.equal(w.ok, false);
    assert.equal(w.needs, 'panes');
    assert.equal(check(home, 'worker.alive', c, { herdr: { panes: { 'pane-w1': true } } }).ok, true);
    assert.equal(check(home, 'worker.alive', c, { herdr: { panes: { 'pane-w1': false } } }).ok, false);
    const conj = check(home, 'home.clean && tabs.clean', c);
    assert.equal(conj.ok, false);
    assert.equal(conj.needs, undefined, 'the cheap fs atom fails first, so no herdr fact is requested');
  });

  test('scout reported', () => {
    const home = buildHome('scout-reported');
    assert.equal(check(home, 'tasks.kind:scout').ok, true);
    assert.equal(check(home, 'backlog.inflight>=1').ok, false, 'a record whose item is still Queued is a spawn in progress');
    assert.equal(check(home, 'report.exists').ok, true);
    assert.equal(check(home, 'report.mentions:greet').ok, true);
    assert.equal(check(home, 'report.mentions:GREET').ok, true, 'case-insensitive');
    assert.equal(check(home, 'report.mentions:pirate').ok, false);
    assert.equal(check(home, 'status.verb:done').ok, true);
    assert.equal(check(home, 'wake.empty').ok, false);
    assert.equal(check(home, 'git.ahead:greeter>=1', ctx({ seeds: { greeter: 'a'.repeat(40) } })).ok, false, 'packed-refs main equals the seed');
    const w = check(home, 'worker.alive', ctx(), { herdr: { panes: { 'pane-s1': true } } });
    assert.equal(w.ok, true, 'a window=herdr:<pane> record names its pane too');
  });

  test('cleaned home keeps the done verb after the task record is gone', () => {
    const home = buildHome('cleaned');
    assert.equal(check(home, 'home.clean').ok, true);
    assert.equal(check(home, 'status.verb:done').ok, true);
    assert.equal(check(home, 'report.exists').ok, false, 'an empty report.md is not a report');
    const c = ctx({ seenTaskIds: new Set(['t1']) });
    assert.equal(check(home, 'home.clean && tabs.clean', c, { herdr: { tabLabels: [] } }).ok, true);
  });

  test('beacon.fresh reads the beacon mtime', () => {
    const home = buildHome('empty');
    const beacon = join(home, 'state', '.last-watcher-beat');
    writeFileSync(beacon, '');
    assert.equal(check(home, 'beacon.fresh').ok, true);
    const old = new Date(Date.now() - 600_000);
    utimesSync(beacon, old, old);
    assert.equal(check(home, 'beacon.fresh').ok, false);
  });
});

// ---- 3. fake-herdr end to end ----------------------------------------------

function makeRoot() {
  const root = tmp('root');
  const git = (...a) => {
    const r = spawnSync('git', ['-C', root, ...a], { encoding: 'utf8' });
    assert.equal(r.status, 0, `git ${a.join(' ')}: ${r.stderr}`);
  };
  git('init', '-q', '-b', 'main');
  mkdirSync(join(root, '.agents', 'skills', 'sample'), { recursive: true });
  writeFileSync(join(root, '.agents', 'skills', 'sample', 'SKILL.md'), '# sample\n');
  mkdirSync(join(root, '.claude'));
  symlinkSync(join('..', '.agents', 'skills'), join(root, '.claude', 'skills'), 'dir');
  writeFileSync(join(root, 'AGENTS.md'), '# test root\n');
  mkdirSync(join(root, 'bin'));
  writeFileSync(join(root, 'bin', '.keep'), '');
  git('add', '-A');
  git('-c', 'user.email=t@example.invalid', '-c', 'user.name=t', 'commit', '-qm', 'root');
  return root;
}

function writeTrace(dir, trace) {
  const p = join(dir, 'trace.json');
  writeFileSync(p, JSON.stringify(trace));
  return p;
}

describe('fake-herdr end to end', () => {
  let root;
  before(() => { root = makeRoot(); });

  test('cloneHome writes an empty regular .fm-control-throwaway marker', async () => {
    const session = new Session({
      trace: { feature: 'throwaway-marker', steps: [] },
      env: { ...process.env, FM_CONTROL_ROOT: root, FM_CONTROL_EVIDENCE: join(tmp('evidence'), 'run') },
    });
    session.scratch = tmp('marker-scratch');
    session.home = join(session.scratch, 'firstmate');
    await session.cloneHome();
    const marker = join(session.home, '.fm-control-throwaway');
    assert.ok(existsSync(marker), 'the throwaway home has the fast-session-start marker');
    const st = lstatSync(marker);
    assert.equal(st.isFile(), true);
    assert.equal(st.isSymbolicLink(), false);
    assert.equal(readFileSync(marker, 'utf8'), '');
    const captain = readFileSync(join(session.home, 'data', 'captain.md'), 'utf8');
    assert.match(captain, /Do not load project-management/);
    assert.match(captain, /Do not run bin\/fm-session-start\.sh/);
    assert.match(captain, /Do not load harness-adapters before spawn/);
    assert.match(captain, /bin\/fm-spawn\.sh/);
  });

  test('throwawayPaneSessionEnv pins the fast session-start opt-in', () => {
    const home = tmp('pane-fast-env');
    assert.deepEqual(throwawayPaneSessionEnv(home), {});
    writeFileSync(join(home, '.fm-control-throwaway'), '');
    const env = throwawayPaneSessionEnv(home);
    assert.equal(env.FM_SESSION_START_FAST, '1');
    assert.equal(env.FM_HOME, env.FM_ROOT_OVERRIDE);
    assert.ok(env.FM_HOME);
  });

  test('ensureThrowawayTools copies treehouse into .tools', () => {
    const home = tmp('tools-home');
    const hostBin = tmp('host-bin');
    const fake = join(hostBin, process.platform === 'win32' ? 'treehouse.exe' : 'treehouse');
    writeFileSync(fake, '#!/bin/sh\necho fake-treehouse\n');
    assert.deepEqual(ensureThrowawayTools(home, { ...process.env, PATH: hostBin }), { skipped: 'not-throwaway' });
    writeFileSync(join(home, '.fm-control-throwaway'), '');
    const result = ensureThrowawayTools(home, { ...process.env, PATH: hostBin, USERPROFILE: dirname(hostBin), HOME: dirname(hostBin) });
    assert.equal(result.skipped, false);
    assert.ok(existsSync(join(home, '.tools', process.platform === 'win32' ? 'treehouse.exe' : 'treehouse')));
    if (process.platform === 'win32') {
      assert.match(readFileSync(join(home, '.tools', 'treehouse'), 'utf8'), /treehouse\.exe/);
    }
  });

  test('a passing trace: says once each, relaunch rotates the lock, result JSON has the contract shape', () => {
    const { dir, env } = fakeEnv({ FM_CONTROL_ROOT: root, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_CONTROL_EVIDENCE: join(tmp('evidence'), 'run') });
    const trace = {
      feature: 'e2e-pass',
      steps: [
        { say: 'ahoy! add my project from {{projectOrigin}} as greeter', until: 'projects.registered:greeter', budgetSec: 10 },
        { say: 'now dispatch a worker', until: 'tasks.count>=1 && status.verb:working', budgetSec: 10 },
        { say: '$relaunch', until: 'tasks.count>=1 && worker.alive', budgetSec: 10 },
        { say: "I'm back", until: 'lock.rotated', budgetSec: 10 },
        { say: 'land it', until: 'status.verb:done', budgetSec: 10 },
        { say: 'clean up', until: 'home.clean && tabs.clean', budgetSec: 10 },
      ],
    };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    assert.equal(r.status, 0, `stdout: ${r.stdout}\nstderr: ${r.stderr}`);
    const j = r.json;
    assert.equal(j.feature, 'e2e-pass');
    assert.equal(j.pass, true);
    assert.equal(typeof j.wallMs, 'number');
    assert.equal(typeof j.readyMs, 'number');
    assert.equal(typeof j.operableMs, 'number');
    assert.equal(typeof j.predicateMs, 'number');
    assert.equal(j.overhead.operableMs, j.operableMs);
    assert.equal(j.steps.length, 6);
    for (const [i, s] of j.steps.entries()) {
      assert.equal(s.until, trace.steps[i].until);
      assert.equal(typeof s.ms, 'number');
      assert.equal(s.ok, true, `step ${i + 1}: ${s.reason}`);
    }
    assert.equal(typeof j.steps[2].relaunchMs, 'number');
    assert.equal(typeof j.overhead.herdrCalls, 'number');
    assert.equal(typeof j.overhead.spawns, 'number');
    assert.ok(j.overhead.herdrCalls > 0);
    assert.ok(j.overhead.spawns >= j.overhead.herdrCalls, 'on the cli transport every call is a spawn');
    assert.equal(j.overhead.transport, 'cli');
    assert.equal(j.predicateMs, j.steps.reduce((a, s) => a + s.ms, 0));

    const state = JSON.parse(readFileSync(join(dir, 'state.json'), 'utf8'));
    const texts = state.sends.filter((s) => s.text !== undefined).map((s) => s.text);
    for (const step of trace.steps) {
      if (step.say === '' || step.say === '$relaunch') continue;
      const expected = step.say.replace('{{projectOrigin}}', j.steps[0].say.match(/from (\S+) as/)[1]);
      assert.equal(texts.filter((t) => t === expected).length, 1, `${JSON.stringify(step.say)} typed exactly once`);
    }
    assert.equal(state.launches, 2, 'one launch plus one relaunch');
    assert.equal(state.exits, 2, 'one /exit for the relaunch, one at close');
    assert.ok(state.env.includes('FM_PANE_PATH'));
    assert.ok(state.env.includes('CLAUDE_CONFIG_DIR'));
    assert.ok(!texts.some((t) => /OAUTH|OATH/.test(t)), 'no token text was ever typed');
    assert.ok(existsSync(join(env.FM_CONTROL_EVIDENCE, 'result.json')));
    assert.ok(existsSync(join(env.FM_CONTROL_EVIDENCE, 'captain.log')));
    assert.ok(existsSync(join(env.FM_CONTROL_EVIDENCE, 'home', 'data', 'projects.md')), 'the home was archived');
    assert.ok(!existsSync(join(env.HOME, '.claude.json')), 'the throwaway config does not mutate ~/.claude.json');
    assert.ok(state.claudeConfigDir, 'the pane received CLAUDE_CONFIG_DIR');
    const isolated = JSON.parse(readFileSync(join(env.FM_CONTROL_EVIDENCE, 'claude-config', '.claude.json'), 'utf8'));
    assert.equal(isolated.hasCompletedOnboarding, true);
    assert.equal(isolated.bypassPermissionsModeAccepted, true);
    assert.equal(Object.values(isolated.projects)[0].hasTrustDialogAccepted, true);
    const theme = JSON.parse(readFileSync(join(env.FM_CONTROL_EVIDENCE, 'claude-config', 'settings.json'), 'utf8'));
    assert.equal(theme.theme, 'dark');
    const calls = readFileSync(join(dir, 'calls.log'), 'utf8').trim().split('\n');
    assert.equal(calls.length, j.overhead.herdrSpawns, 'the driver counted every herdr process it started');
  });

  test('an empty say waits without typing', () => {
    const { dir, env } = fakeEnv({ FM_CONTROL_ROOT: root, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_CONTROL_EVIDENCE: join(tmp('evidence'), 'run') });
    const trace = {
      feature: 'e2e-wait',
      steps: [
        { say: 'now dispatch a worker', until: 'tasks.count>=1', budgetSec: 10 },
        { say: '', until: 'status.verb:working', budgetSec: 10 },
      ],
    };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    assert.equal(r.status, 0, r.stderr);
    const state = JSON.parse(readFileSync(join(dir, 'state.json'), 'utf8'));
    const texts = state.sends.filter((s) => s.text !== undefined && !/claude --dangerously|^\/exit$/.test(s.text)).map((s) => s.text);
    assert.deepEqual(texts, ['now dispatch a worker']);
  });

  test('a dead primary fails its step at once', () => {
    const { env } = fakeEnv({ FM_CONTROL_ROOT: root, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_CONTROL_EVIDENCE: join(tmp('evidence'), 'run') });
    const trace = {
      feature: 'e2e-dead',
      steps: [
        { say: 'crash now', until: 'tasks.count>=1', budgetSec: 60 },
        { say: 'never typed', until: 'home.clean', budgetSec: 60 },
      ],
    };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    assert.equal(r.status, 1, r.stderr);
    assert.equal(r.json.pass, false);
    assert.equal(r.json.steps.length, 1, 'the trace stops at the failed step');
    assert.equal(r.json.steps[0].ok, false);
    assert.match(r.json.steps[0].reason, /exited/);
    assert.ok(r.json.steps[0].ms < 5000, `failed fast, not at the 60 s budget (${r.json.steps[0].ms} ms)`);
  });

  test('a claim that never holds fails at its budget, not before', () => {
    const { env } = fakeEnv({ FM_CONTROL_ROOT: root, FM_CONTROL_EVIDENCE: join(tmp('evidence'), 'run') });
    const trace = { feature: 'e2e-timeout', steps: [{ say: 'do nothing', until: 'tasks.count>=1', budgetSec: 1.5 }] };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    assert.equal(r.status, 1, r.stderr);
    assert.equal(r.json.pass, false);
    assert.match(r.json.steps[0].reason, /not within/);
    assert.ok(r.json.steps[0].ms >= 1400 && r.json.steps[0].ms < 4000, `budget honoured (${r.json.steps[0].ms} ms)`);
  });

  test('the shipped restart-primary trace passes against the fake, and the run is cheap', () => {
    const { dir, env } = fakeEnv({ FM_CONTROL_ROOT: root, FAKE_HERDR_SCRIPT: join(FIXTURES, 'restart-primary-script.json'), FM_CONTROL_EVIDENCE: join(tmp('evidence'), 'run') });
    const r = runDrive(['run', join(HERE, '..', 'traces', 'restart-primary.json')], env);
    assert.equal(r.status, 0, `stdout: ${r.stdout}\nstderr: ${r.stderr}`);
    const j = r.json;
    assert.equal(j.pass, true);
    assert.equal(j.steps.length, 6);
    assert.ok(j.steps.every((s) => s.ok), JSON.stringify(j.steps));
    assert.equal(j.overhead.gitSpawns, 1, 'git.ahead cost exactly one git process');
    // Measured fake restart-primary wall: 49206 ms on Windows vs ~1734 ms on Linux.
    assert.ok(j.wallMs < (process.platform === 'win32' ? 120_000 : 30_000), `fake run finished in ${j.wallMs} ms`);
    const state = JSON.parse(readFileSync(join(dir, 'state.json'), 'utf8'));
    const texts = state.sends.filter((s) => s.text !== undefined).map((s) => s.text);
    assert.equal(texts.filter((t) => t.startsWith('ahoy! add my project')).length, 1);
    assert.equal(texts.filter((t) => t.startsWith("ahoy, I'm back")).length, 1);
    assert.equal(state.launches, 2);
  });

  test('a rejected trace never reaches herdr even with a live fake', () => {
    const { dir, env } = fakeEnv({ FM_CONTROL_ROOT: root });
    const r = runDrive(['run', join(FIXTURES, 'reject', 'lock-only.json')], env);
    assert.equal(r.status, 2);
    assert.ok(!existsSync(join(dir, 'calls.log')));
  });

  test('first say waits for a delayed lock when the pane shows session-start', () => {
    const { dir, env } = fakeEnv({
      FM_CONTROL_ROOT: root,
      FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'),
      FAKE_HERDR_LOCK_DELAY_MS: '2500',
      FAKE_HERDR_PANE_UNTIL_LOCK: 'bypass permissions on\nRunning Bash: bin/fm-session-start.sh\n',
      FM_CONTROL_OPERABLE_MS: '15000',
      FM_CONTROL_EVIDENCE: join(tmp('evidence'), 'run'),
    });
    const evidence = env.FM_CONTROL_EVIDENCE;
    const trace = {
      feature: 'e2e-operable-wait',
      steps: [{ say: 'ahoy! add my project from {{projectOrigin}} as greeter', until: 'projects.registered:greeter', budgetSec: 10 }],
    };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.json.pass, true);
    assert.ok(!existsSync(join(evidence, 'prestart.txt')), 'fake runs do not pre-start session-start');
    const state = JSON.parse(readFileSync(join(dir, 'state.json'), 'utf8'));
    const firstSay = state.sends.find((s) => s.text && s.text.startsWith('ahoy! add my project'));
    assert.ok(firstSay, 'the first captain say was typed');
    assert.ok(state.lockAt, 'the fake recorded when the lock appeared');
    assert.ok(firstSay.t >= state.lockAt, `say ${firstSay.t} was after lock ${state.lockAt}`);
    assert.ok(r.json.operableMs >= 1500, `operable wait ${r.json.operableMs} ms`);
  });

  test('a persistent-cd session-start denial does not send Escape', () => {
    const { dir, env } = fakeEnv({
      FM_CONTROL_ROOT: root,
      FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'),
      FAKE_HERDR_STATUS: 'blocked',
      FAKE_HERDR_PANE: 'bypass permissions on\nBash: cd /tmp/home && bin/fm-session-start.sh\nDenied by persistent-cd hook\n',
      FM_CONTROL_EVIDENCE: join(tmp('evidence'), 'run'),
    });
    const trace = {
      feature: 'e2e-cd-denied',
      steps: [{ say: 'ahoy! add my project from {{projectOrigin}} as greeter', until: 'projects.registered:greeter', budgetSec: 10 }],
    };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    assert.equal(r.status, 0, r.stderr);
    const state = JSON.parse(readFileSync(join(dir, 'state.json'), 'utf8'));
    const escapes = state.sends.filter((s) => Array.isArray(s.keys) && s.keys.includes('escape'));
    assert.equal(escapes.length, 0, 'Escape was not sent for a session-start persistent-cd denial');
  });

  test('a folder-trust dialog is accepted with Down then Enter', () => {
    const { dir, env } = fakeEnv({
      FM_CONTROL_ROOT: root,
      FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'),
      FAKE_HERDR_TRUST: '1',
      FM_CONTROL_EVIDENCE: join(tmp('evidence'), 'run'),
    });
    const trace = {
      feature: 'e2e-trust',
      steps: [{ say: 'ahoy! add my project from {{projectOrigin}} as greeter', until: 'projects.registered:greeter', budgetSec: 10 }],
    };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    assert.equal(r.status, 0, r.stderr);
    const state = JSON.parse(readFileSync(join(dir, 'state.json'), 'utf8'));
    const keys = state.sends.filter((s) => Array.isArray(s.keys)).flatMap((s) => s.keys);
    const downAt = keys.indexOf('down');
    const enterAt = keys.indexOf('enter');
    assert.ok(downAt >= 0, 'Down moved the cursor off No, exit');
    assert.ok(enterAt > downAt, 'Enter confirmed Yes after Down');
  });

  test('a stuck folder-trust dialog fails the run inside the trust bound', () => {
    const { env } = fakeEnv({
      FM_CONTROL_ROOT: root,
      FAKE_HERDR_PANE: ' ❯ No, exit\n   Yes, I trust this folder\n',
      FM_CONTROL_TRUST_MS: '2500',
      FM_CONTROL_READY_MS: '20000',
      FM_CONTROL_EVIDENCE: join(tmp('evidence'), 'run'),
    });
    const trace = { feature: 'e2e-trust-stuck', steps: [{ say: 'ahoy', until: 'projects.registered:greeter', budgetSec: 60 }] };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    assert.equal(r.status, 3, r.stderr);
    assert.match(r.json.error, /folder trust/);
    assert.equal(r.json.readyMs, null, 'ready must not fire while trust is up');
    assert.ok(r.json.wallMs < (process.platform === 'win32' ? 90_000 : 30_000), `failed inside the bound (${r.json.wallMs} ms)`);
  });
});

// ---- 4. cli transport mapping ----------------------------------------------

describe('cli transport argv mapping', () => {
  test('send_input with enter is pane run; keys alone are send-keys', () => {
    assert.deepEqual(cliArgv('pane.send_input', { pane_id: 'p', text: 'hi', keys: ['enter'] }), ['pane', 'run', 'p', 'hi']);
    assert.deepEqual(cliArgv('pane.send_input', { pane_id: 'p', keys: ['down'] }), ['pane', 'send-keys', 'p', 'down']);
    assert.deepEqual(cliArgv('pane.read', { pane_id: 'p', source: 'recent_unwrapped' }), ['pane', 'read', 'p', '--source', 'recent-unwrapped']);
    assert.throws(() => cliArgv('nope.method', {}));
  });
});

describe('grafted onboarding config and shell prompts', () => {
  test("B's throwaway CLAUDE_CONFIG_DIR is created and does not write ~/.claude.json", () => {
    const home = tmp('claude-home');
    const userHome = tmp('user-home');
    const dir = prepareClaudeConfig(home, { HOME: userHome, USERPROFILE: userHome });
    assert.equal(dir, join(home, '.fm-control-claude'));
    const cfg = JSON.parse(readFileSync(join(dir, '.claude.json'), 'utf8'));
    assert.equal(cfg.hasCompletedOnboarding, true);
    assert.equal(cfg.bypassPermissionsModeAccepted, true);
    assert.equal(cfg.projects[home].hasTrustDialogAccepted, true);
    assert.equal(cfg.projects[home.replace(/\\/g, '/')].hasTrustDialogAccepted, true);
    for (const key of trustProjectKeys(home)) {
      assert.equal(cfg.projects[key].hasTrustDialogAccepted, true, key);
    }
    const settings = JSON.parse(readFileSync(join(dir, 'settings.json'), 'utf8'));
    assert.equal(settings.theme, 'dark');
    assert.ok(!existsSync(join(userHome, '.claude.json')));
    assert.ok(!existsSync(join(dir, '.credentials.json')), 'no credentials file when the host has none');
  });

  test('throwaway config inherits host claude.ai login files by presence and shape', () => {
    const home = tmp('claude-home');
    const userHome = tmp('user-home');
    mkdirSync(join(userHome, '.claude'), { recursive: true });
    writeFileSync(
      join(userHome, '.claude', '.credentials.json'),
      `${JSON.stringify({
        claudeAiOauth: { accessToken: 'x', refreshToken: 'y', expiresAt: 1, scopes: ['user:inference'] },
      })}\n`,
      { mode: 0o600 },
    );
    writeFileSync(
      join(userHome, '.claude.json'),
      `${JSON.stringify({
        oauthAccount: { accountUuid: '00000000-0000-4000-8000-000000000000', emailAddress: 'user@example.invalid' },
        hasCompletedOnboarding: false,
        theme: 'light',
      })}\n`,
    );
    const dir = prepareClaudeConfig(home, { HOME: userHome, USERPROFILE: userHome });
    assert.ok(existsSync(join(dir, '.credentials.json')), 'credentials file is present in the throwaway dir');
    const creds = JSON.parse(readFileSync(join(dir, '.credentials.json'), 'utf8'));
    assert.equal(typeof creds.claudeAiOauth, 'object');
    assert.equal(typeof creds.claudeAiOauth.accessToken, 'string');
    assert.ok(creds.claudeAiOauth.accessToken.length > 0);
    assert.equal(typeof creds.claudeAiOauth.refreshToken, 'string');
    assert.ok(Array.isArray(creds.claudeAiOauth.scopes));
    const cfg = JSON.parse(readFileSync(join(dir, '.claude.json'), 'utf8'));
    assert.equal(cfg.hasCompletedOnboarding, true, 'onboarding flags still win over the host file');
    assert.equal(cfg.bypassPermissionsModeAccepted, true);
    assert.equal(typeof cfg.oauthAccount, 'object');
    assert.equal(typeof cfg.oauthAccount.accountUuid, 'string');
    assert.ok(cfg.oauthAccount.accountUuid.length > 0);
    const host = JSON.parse(readFileSync(join(userHome, '.claude.json'), 'utf8'));
    assert.equal(host.hasCompletedOnboarding, false, 'the host ~/.claude.json is not mutated');
    assert.ok(!host.bypassPermissionsModeAccepted);
  });

  test('evidence archival keeps onboarding shape and omits inherited login material', () => {
    const home = tmp('claude-home');
    const userHome = tmp('user-home');
    mkdirSync(join(userHome, '.claude'), { recursive: true });
    writeFileSync(
      join(userHome, '.claude', '.credentials.json'),
      `${JSON.stringify({ claudeAiOauth: { accessToken: 'x', refreshToken: 'y' } })}\n`,
    );
    writeFileSync(
      join(userHome, '.claude.json'),
      `${JSON.stringify({ oauthAccount: { accountUuid: 'acct' }, hasCompletedOnboarding: true })}\n`,
    );
    const dir = prepareClaudeConfig(home, { HOME: userHome, USERPROFILE: userHome });
    const evidence = tmp('claude-evidence');
    archiveClaudeConfig(dir, evidence);
    assert.ok(!existsSync(join(evidence, '.credentials.json')), 'credentials are not copied into evidence');
    const archived = JSON.parse(readFileSync(join(evidence, '.claude.json'), 'utf8'));
    assert.equal(archived.hasCompletedOnboarding, true);
    assert.equal(archived.bypassPermissionsModeAccepted, true);
    assert.equal(archived.oauthAccount, undefined);
    for (const key of Object.keys(archived)) assert.equal(isAuthStateKey(key), false);
    assert.equal(isCredentialFileName('.credentials.json'), true);
    const theme = JSON.parse(readFileSync(join(evidence, 'settings.json'), 'utf8'));
    assert.equal(theme.theme, 'dark');
  });

  test('waitUntil keeps a claim that already holds when the primary then asks a question', async () => {
    const home = buildHome('ship-in-flight');
    const started = Date.now();
    const r = await waitUntil({
      home,
      parsed: parseUntil('projects.registered:greeter'),
      ctx: { lockBaseline: undefined, seeds: {}, seenTaskIds: new Set() },
      budgetMs: 5000,
      deps: {
        liveness: async () => ({ alive: true, reason: 'test' }),
        signals: { blocked: 'herdr reports the primary blocked on a question' },
        fetchHerdr: async () => {},
        gitAhead: {},
        seeds: {},
        counters: {},
      },
    });
    assert.equal(r.ok, true, r.reason);
    assert.ok(Date.now() - started < 2000, `resolved immediately (${Date.now() - started} ms)`);
  });

  test('isTrustPrompt matches the Claude 2.1 folder dialog', () => {
    assert.equal(isTrustPrompt(' ❯ No, exit\n   Yes, I trust this folder\n'), true);
    assert.equal(isTrustPrompt('bypass permissions on'), false);
  });

  test('trustProjectKeys includes slash and drive-letter forms', () => {
    const keys = trustProjectKeys('C:\\Users\\me\\tmp\\firstmate');
    assert.ok(keys.includes('C:\\Users\\me\\tmp\\firstmate'));
    assert.ok(keys.includes('C:/Users/me/tmp/firstmate'));
    assert.ok(keys.includes('c:/Users/me/tmp/firstmate'));
  });

  test("C's prompt patterns match Git Bash, Linux cwd, and Windows shells", () => {
    assert.equal(atShellPrompt('$'), true);
    assert.equal(atShellPrompt('$ '), true);
    assert.equal(atShellPrompt('firstmate $'), true);
    assert.equal(atShellPrompt('claude --resume abc\nfirstmate $'), true);
    assert.equal(atShellPrompt('PS C:\\Users\\me\\firstmate>'), true);
    assert.equal(atShellPrompt('C:\\Users\\me\\firstmate>'), true);
    assert.equal(atShellPrompt('bypass permissions on'), false);
    assert.equal(atShellPrompt('Welcome to Claude\n'), false);
    assert.equal(atShellPrompt(''), false);
    assert.equal(atShellPrompt('> '), false, 'a lone agent composer glyph is not a shell prompt');
  });
});

describe('operable home gate', () => {
  test('homeIsOperable is lock or session-start-complete', () => {
    const home = tmp('operable-home');
    assert.equal(homeIsOperable(home), false);
    mkdirSync(join(home, 'state'), { recursive: true });
    writeFileSync(join(home, 'state', '.lock'), '1\n');
    assert.equal(homeIsOperable(home), true);
    rmSync(join(home, 'state', '.lock'));
    assert.equal(homeIsOperable(home), false);
    writeFileSync(join(home, 'state', '.session-start-complete'), '1\n');
    assert.equal(homeIsOperable(home), true);
  });

  test('isSessionStartBusy matches fm-session-start, including a persistent-cd denial', () => {
    assert.equal(isSessionStartBusy('bypass permissions on'), false);
    assert.equal(isSessionStartBusy('Bash: cd /tmp/home && bin/fm-session-start.sh\nDenied by persistent-cd hook'), true);
    assert.equal(isSessionStartBusy('Running bin/fm-session-start.sh'), true);
    assert.equal(isSessionStartBusy(''), false);
  });

  test('isThrowawayControlHome requires a regular marker', () => {
    const home = tmp('throwaway-marker');
    assert.equal(isThrowawayControlHome(home), false);
    writeFileSync(join(home, '.fm-control-throwaway'), '');
    assert.equal(isThrowawayControlHome(home), true);
  });

  test('stripThrowawaySessionStartHooks removes SessionStart and PreToolUse on a marked home', () => {
    const home = tmp('strip-hooks');
    mkdirSync(join(home, '.claude'), { recursive: true });
    writeFileSync(join(home, '.claude', 'settings.json'), `${JSON.stringify({
      hooks: {
        SessionStart: [{ hooks: [{ type: 'command', command: 'fm-sessionstart-run.sh' }] }],
        PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command: 'fm-cd-pretool-check.sh' }] }],
        Stop: [{ hooks: [{ type: 'command', command: 'fm-turnend-guard.sh' }] }],
      },
    })}\n`);
    assert.equal(stripThrowawaySessionStartHooks(home).skipped, 'not-throwaway');
    assert.ok(JSON.parse(readFileSync(join(home, '.claude', 'settings.json'), 'utf8')).hooks.SessionStart);
    writeFileSync(join(home, '.fm-control-throwaway'), '');
    assert.equal(stripThrowawaySessionStartHooks(home).skipped, false);
    const hooks = JSON.parse(readFileSync(join(home, '.claude', 'settings.json'), 'utf8')).hooks;
    assert.equal(hooks.SessionStart, undefined);
    assert.equal(hooks.PreToolUse, undefined);
    assert.ok(hooks.Stop);
  });

  test('controlBashPath honors FM_CONTROL_BASH', () => {
    assert.equal(controlBashPath({ FM_CONTROL_BASH: 'C:\\git\\bash.exe' }), 'C:\\git\\bash.exe');
  });

  test('prestartThrowawayHome is a no-op without the marker or when disabled', async () => {
    const home = tmp('prestart-skip');
    mkdirSync(join(home, 'state'), { recursive: true });
    const skipped = await prestartThrowawayHome(home, { env: { ...process.env } });
    assert.equal(skipped.skipped, 'not-throwaway');
    writeFileSync(join(home, '.fm-control-throwaway'), '');
    const disabled = await prestartThrowawayHome(home, { env: { ...process.env, FM_CONTROL_PRESTART: '0' } });
    assert.equal(disabled.skipped, 'disabled');
    assert.equal(homeIsOperable(home), false);
  });

  test('prestartThrowawayHome writes the lock and fails closed on a missing lock', async () => {
    const bash = controlBashPath(process.env);
    if (!bash) {
      assert.ok(true, 'no Git Bash on this host; skip the live pre-start cases');
      return;
    }
    const okHome = tmp('prestart-ok');
    mkdirSync(join(okHome, 'bin'), { recursive: true });
    mkdirSync(join(okHome, 'state'), { recursive: true });
    writeFileSync(join(okHome, '.fm-control-throwaway'), '');
    writeFileSync(join(okHome, 'bin', 'fm-session-start.sh'), '#!/usr/bin/env bash\nprintf \'1\\n\' > "$FM_HOME/state/.lock"\n');
    const ok = await prestartThrowawayHome(okHome, { env: { ...process.env, FM_CONTROL_BASH: bash }, timeoutMs: 15_000 });
    assert.equal(ok.skipped, false);
    assert.equal(homeIsOperable(okHome), true);

    const miss = tmp('prestart-miss');
    mkdirSync(join(miss, 'bin'), { recursive: true });
    mkdirSync(join(miss, 'state'), { recursive: true });
    writeFileSync(join(miss, '.fm-control-throwaway'), '');
    writeFileSync(join(miss, 'bin', 'fm-session-start.sh'), '#!/usr/bin/env bash\nexit 0\n');
    await assert.rejects(
      () => prestartThrowawayHome(miss, { env: { ...process.env, FM_CONTROL_BASH: bash }, timeoutMs: 15_000 }),
      /without a lock or completion record/,
    );

    const bad = tmp('prestart-bad');
    mkdirSync(join(bad, 'bin'), { recursive: true });
    mkdirSync(join(bad, 'state'), { recursive: true });
    writeFileSync(join(bad, '.fm-control-throwaway'), '');
    writeFileSync(join(bad, 'bin', 'fm-session-start.sh'), '#!/usr/bin/env bash\nexit 2\n');
    await assert.rejects(
      () => prestartThrowawayHome(bad, { env: { ...process.env, FM_CONTROL_BASH: bash }, timeoutMs: 15_000 }),
      /exited 2/,
    );
  });
});

test('no module spawns a shell', () => {
  for (const f of ['drive.mjs', 'lib/herdr.mjs', 'lib/session.mjs', 'lib/wait.mjs']) {
    const src = readFileSync(join(HERE, '..', f), 'utf8');
    assert.ok(!/shell:\s*true/.test(src), `${f} never spawns through a shell`);
    assert.ok(!/execSync|exec\(/.test(src), `${f} never uses exec`);
  }
});

// keep the helper referenced for platforms where spawn is unused by tests
void spawn;
