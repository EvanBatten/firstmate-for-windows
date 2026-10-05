import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync, spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, rmSync, symlinkSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { parseUntil, evaluateUntil, snapshotHome, CATALOG } from '../lib/predicates.mjs';
import { validateTrace, TraceError } from '../lib/trace.mjs';
import { atShellPrompt, cliArgv } from '../lib/herdr.mjs';
import { prepareClaudeConfig, archiveClaudeConfig, isAuthStateKey, isCredentialFileName, homeIsOperable, isSessionStartBusy, isTrustPrompt, trustProjectKeys } from '../lib/session.mjs';
import { waitUntil } from '../lib/wait.mjs';
import * as sessionLib from '../lib/session.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const DRIVE = join(HERE, '..', 'drive.mjs');
const FAKE = join(HERE, 'fake-herdr.mjs');
const FIXTURES = join(HERE, 'fixtures');
const REPO = join(HERE, '..', '..', '..');
const NODE = process.execPath;

const scratch = [];
function tmp(prefix) {
  const d = mkdtempSync(join(tmpdir(), `fm-drive-test-${prefix}-`));
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
      FM_DRIVE_HERDR: FAKE,
      FM_DRIVE_TRANSPORT: 'cli',
      FM_DRIVE_QUIET: '1',
      FM_DRIVE_READY_MS: '20000',
      FAKE_HERDR_DIR: fakeDir,
      ...extra,
    },
  };
}

function runDrive(args, env) {
  const r = spawnSync(NODE, [DRIVE, ...args], { env, encoding: 'utf8', timeout: 120_000 });
  let json = null;
  try { json = JSON.parse(r.stdout.trim().split('\n').at(-1)); } catch {}
  return { status: r.status, stdout: r.stdout, stderr: r.stderr, json };
}

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
      if (!f.includes('budget')) assert.doesNotMatch(r.json.rejected, /budgetSec/, 'the fixture is refused for its own reason, not a missing budget');
      assert.ok(!existsSync(join(dir, 'calls.log')), 'the fake herdr was never invoked');
      assert.ok(!existsSync(join(dir, 'state.json')), 'no herdr state was created');
    });
  }

  test('check refuses a say that steers the primary with internals, before any herdr call', () => {
    const steering = rejects.filter((f) => f.startsWith('steer-')).sort();
    assert.deepEqual(steering, [
      'steer-agent-skill.json', 'steer-bin-mixed-case.json', 'steer-bin-spawn.json', 'steer-bin-upper.json', 'steer-fm-brief.json', 'steer-skill-dotdot.json', 'steer-skill-path.json', 'steer-skill-top-level.json',
    ]);
    for (const f of steering) {
      const { dir, env } = fakeEnv();
      const r = runDrive(['check', join(FIXTURES, 'reject', f)], env);
      assert.equal(r.status, 2, `${f}: ${r.stdout}`);
      assert.match(r.json?.rejected ?? '', /steers the primary/, f);
      assert.ok(!existsSync(join(dir, 'calls.log')), `${f}: the fake herdr was never invoked`);
    }
  });

  test('check refuses a trace whose every until already holds on a fresh clone of the home', () => {
    const vacuous = rejects.filter((f) => f.startsWith('vacuous-')).sort();
    assert.deepEqual(vacuous, ['vacuous-file-contains.json', 'vacuous-home-clean.json', 'vacuous-wake-empty.json']);
    for (const f of vacuous) {
      const { dir, env } = fakeEnv();
      const r = runDrive(['check', join(FIXTURES, 'reject', f)], env);
      assert.equal(r.status, 2, `${f}: ${r.stdout}`);
      assert.match(r.json?.rejected ?? '', /already holds on a fresh clone/, f);
      assert.ok(!existsSync(join(dir, 'calls.log')), `${f}: the fake herdr was never invoked`);
    }
  });

  test('check refuses a trace with a step that has no budget', () => {
    const r = runDrive(['check', join(FIXTURES, 'reject', 'no-budget.json')], fakeEnv().env);
    assert.equal(r.status, 2, r.stdout);
    assert.equal(r.stderr, 'fm-drive: trace rejected: steps[1].budgetSec must be a positive number of seconds\n');
  });

  test('an ordinary captain request passes check', () => {
    const r = runDrive(['check', join(FIXTURES, 'allow', 'ordinary-captain.json')], fakeEnv().env);
    assert.equal(r.status, 0, r.stdout);
    assert.equal(r.json.ok, true);
  });

  const STEERING = JSON.parse(readFileSync(join(FIXTURES, 'steering.json'), 'utf8'));
  const refusal = (say) => {
    try {
      validateTrace({ feature: 'x', steps: [{ say, until: 'projects.registered:greeter', budgetSec: 60 }] }, { root: REPO });
      return null;
    } catch (err) {
      if (!(err instanceof TraceError)) throw err;
      return err.message;
    }
  };

  test('real captain lines pass, including worker tab names and plain words that match skill names', () => {
    const refused = STEERING.captain.map((say) => [say, refusal(say)]).filter(([, why]) => why);
    assert.deepEqual(refused, []);
  });

  test('a path to a script in bin/ or a skill, or an agent-only skill invoked as a skill, is refused in any folded spelling', () => {
    const allowed = STEERING.refused.filter((say) => !/steers the primary/.test(refusal(say) ?? ''));
    assert.deepEqual(allowed, []);
  });

  test('a say where the word skills is followed by a skill name is refused as a path into that skill, even in plain words', () => {
    const allowed = STEERING.wordsRefused.filter((say) => !/invokes the skill file .*steers the primary/.test(refusal(say) ?? ''));
    assert.deepEqual(allowed, []);
  });

  test('respellings that name no bin/ script and invoke no skill are left to the trace reviewer', () => {
    const refused = STEERING.allowed.map((say) => [say, refusal(say)]).filter(([, why]) => why);
    assert.deepEqual(refused, []);
  });

  test('the skill doc lists the shell-obfuscated script names it leaves to the reviewer instead of claiming every spelling', () => {
    const doc = readFileSync(join(REPO, '.agents', 'skills', 'control-firstmate', 'SKILL.md'), 'utf8');
    assert.deepEqual(STEERING.obfuscated.map((say) => [say, refusal(`run ${say} greeter`)]).filter(([, why]) => why), []);
    assert.deepEqual(STEERING.obfuscated.filter((name) => !doc.includes(`\`${name}\``)), []);
    assert.doesNotMatch(doc, /every spelling/);
  });

  test('bin scripts and skills come from every skill directory of the driven root at check time', () => {
    const rich = makeRoot({
      'bin/zebra-run.sh': '#!/bin/sh\n',
      '.agents/skills/zebra-runbook/SKILL.md': '---\nname: zebra-runbook\nuser-invocable: false\n---\n# zebra\n',
      '.agents/skills/zebra-guide/SKILL.md': '---\nname: zebra-guide\n---\n# zebra\n',
      'skills/zebra-top/SKILL.md': '---\nname: zebra-top\n---\n# zebra\n',
      'skills/zebra-guide/SKILL.md': '---\nname: zebra-guide\n---\n# zebra\n',
      'skills/zebra-notes.md': '# not a skill\n',
    });
    const claudeOnly = makeRoot({
      '.claude/skills/zebra-claude/SKILL.md': '---\nname: zebra-claude\nuser-invocable: false\n---\n# zebra\n',
    }, { claudeSkillsLink: false });
    const plain = makeRoot();
    const cases = {
      script: ['run bin/zebra-run.sh for greeter', /the script bin\/zebra-run\.sh/],
      skill: ['/zebra-runbook for greeter', /the agent-only skill zebra-runbook/],
      path: ['read skills/zebra-guide/SKILL.md for greeter', /the skill file \.agents\/skills\/zebra-guide\/SKILL\.md or skills\/zebra-guide\/SKILL\.md;/],
      claudePath: ['read .claude/skills/zebra-claude/SKILL.md for greeter', /the skill file \.claude\/skills\/zebra-claude\//],
      claudeSkill: ['/zebra-claude for greeter', /the agent-only skill zebra-claude/],
      topPath: ['follow skills/zebra-top/SKILL.md for greeter', /the skill file skills\/zebra-top\//],
      dotdot: ['follow .agents/skills/zebra-guide/../zebra-top/SKILL.md for greeter', /the skill file skills\/zebra-top\//],
      words: ['open the Zebra Runbook for greeter', /^$/],
      file: ['read skills/zebra-notes.md for greeter', /^$/],
    };
    const verdicts = {};
    for (const [label, [say]] of Object.entries(cases)) {
      const trace = writeTrace(tmp('trace'), { feature: 'zebra', steps: [{ say, until: 'projects.registered:greeter', budgetSec: 1 }] });
      const r = runDrive(['check', trace], fakeEnv({ FM_DRIVE_ROOT: label.startsWith('claude') ? claudeOnly : rich }).env);
      verdicts[label] = { rich: r.status, why: r.json?.rejected ?? '', plain: runDrive(['check', trace], fakeEnv({ FM_DRIVE_ROOT: plain }).env).status };
    }
    assert.deepEqual(
      Object.fromEntries(Object.entries(verdicts).map(([k, v]) => [k, [v.rich, cases[k][1].test(v.why), v.plain]])),
      {
        script: [2, true, 0], skill: [2, true, 0], path: [2, true, 0], claudePath: [2, true, 0],
        claudeSkill: [2, true, 0], topPath: [2, true, 0], dotdot: [2, true, 0], words: [0, true, 0], file: [0, true, 0],
      },
      JSON.stringify(verdicts),
    );
  });

  test('a missing trace file exits 2', () => {
    const { dir, env } = fakeEnv();
    const r = runDrive(['run', join(FIXTURES, 'reject', 'does-not-exist.json')], env);
    assert.equal(r.status, 2);
    assert.ok(!existsSync(join(dir, 'calls.log')));
  });

  test('the shipped traces validate through check', () => {
    const shipped = readdirSync(join(HERE, '..', 'traces')).sort();
    assert.deepEqual(shipped, ['register.json', 'restart-primary.json', 'scout-report.json']);
    const steps = { register: 1, 'restart-primary': 5, 'scout-report': 6 };
    for (const [name, count] of Object.entries(steps)) {
      const r = runDrive(['check', join(HERE, '..', 'traces', `${name}.json`)], process.env);
      assert.equal(r.status, 0, r.stderr);
      assert.equal(r.json.feature, name);
      assert.equal(r.json.steps.length, count);
    }
  });

  test('validateTrace refuses the startup-only shapes in process', () => {
    assert.throws(() => validateTrace({ feature: 'x', steps: [{ say: '', until: 'pong', budgetSec: 60 }] }), TraceError);
    assert.throws(() => validateTrace({ feature: 'x', steps: [{ say: '', until: 'bypass permissions on', budgetSec: 60 }] }), TraceError);
    assert.throws(() => validateTrace({ feature: 'x', steps: [{ say: '', until: 'lock.held', budgetSec: 60 }, { say: '', until: 'lock.held', budgetSec: 60 }] }), TraceError);
    const ok = validateTrace({ feature: 'x', steps: [{ say: '', until: 'lock.held', budgetSec: 60 }, { say: 'go', until: 'tasks.count>=1', budgetSec: 60 }] });
    assert.equal(ok.steps.length, 2);
    assert.equal(ok.steps[1].parsed.atoms[0].name, 'tasks.count');
  });

  test('every catalog entry parses in at least one spelling', () => {
    const samples = ['projects.registered:greeter', 'tasks.count>=1', 'backlog.inflight>=1', 'tasks.kind:scout', 'status.verb:done', 'report.exists', 'report.mentions:greet', 'inbox.handled', 'lock.held', 'lock.rotated', 'git.ahead:greeter>=1', 'home.clean', 'tabs.clean', 'worker.alive', 'wake.empty', 'beacon.fresh', 'file.contains:data/projects.md:greeter'];
    const names = new Set(samples.map((s) => parseUntil(s).atoms[0].name));
    for (const c of CATALOG) assert.ok(names.has(c), `catalog entry ${c} has a sample`);
  });
});

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

  test('status.verb matches a done line that carries an [at=] tag', () => {
    const home = buildHome('tagged-done');
    assert.deepEqual(check(home, 'status.verb:done'), { ok: true, reason: 'holds' });
    assert.equal(check(home, 'status.verb:failed').ok, false);
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

// The repo's hook layout, so a driver that strips or rewrites hooks is caught.
const REPO_SETTINGS = `${JSON.stringify({
  hooks: {
    SessionStart: [{ hooks: [{ type: 'command', command: '"$CLAUDE_PROJECT_DIR"/bin/fm-sessionstart-run.sh; exit 0', timeout: 180 }] }],
    PreToolUse: [
      { matcher: 'Bash', hooks: [{ type: 'command', command: 'exec "$CLAUDE_PROJECT_DIR"/bin/fm-cd-pretool-check.sh --claude' }] },
      { matcher: '.*', hooks: [{ type: 'command', command: '"$CLAUDE_PROJECT_DIR"/bin/fm-subagent-pretool-check.sh --claude' }] },
    ],
    Stop: [{ hooks: [{ type: 'command', command: 'exec "$CLAUDE_PROJECT_DIR"/bin/fm-turnend-guard.sh --claude' }] }],
  },
}, null, 2)}\n`;

function makeRoot(extraFiles = {}, { claudeSkillsLink = true } = {}) {
  const root = tmp('root');
  const git = (...a) => {
    const r = spawnSync('git', ['-C', root, ...a], { encoding: 'utf8' });
    assert.equal(r.status, 0, `git ${a.join(' ')}: ${r.stderr}`);
  };
  git('init', '-q', '-b', 'main');
  // Like the repo: LF everywhere, so a Git for Windows autocrlf default does not rewrite the clone.
  writeFileSync(join(root, '.gitattributes'), '* text=auto eol=lf\n');
  mkdirSync(join(root, '.agents', 'skills', 'sample'), { recursive: true });
  writeFileSync(join(root, '.agents', 'skills', 'sample', 'SKILL.md'), '# sample\n');
  mkdirSync(join(root, '.claude'));
  if (claudeSkillsLink) symlinkSync(join('..', '.agents', 'skills'), join(root, '.claude', 'skills'), 'dir');
  writeFileSync(join(root, '.claude', 'settings.json'), REPO_SETTINGS);
  writeFileSync(join(root, 'AGENTS.md'), '# test root\n');
  mkdirSync(join(root, 'bin'));
  writeFileSync(join(root, 'bin', '.keep'), '');
  for (const [rel, content] of Object.entries(extraFiles)) {
    mkdirSync(dirname(join(root, rel)), { recursive: true });
    writeFileSync(join(root, rel), content);
  }
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

  test('a passing trace: says once each, relaunch rotates the lock, result JSON has the contract shape', () => {
    const { dir, env } = fakeEnv({ FM_DRIVE_ROOT: root, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run') });
    const trace = {
      feature: 'e2e-pass',
      steps: [
        { say: 'ahoy! add my project from {{projectOrigin}} as greeter', until: 'projects.registered:greeter', budgetSec: 10 },
        { say: 'now dispatch a worker', until: 'tasks.count>=1 && status.verb:working', budgetSec: 10 },
        { say: '$relaunch', until: 'tasks.count>=1 && worker.alive && lock.rotated', budgetSec: 10 },
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
    assert.equal(j.steps.length, 5);
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
    assert.ok(existsSync(join(env.FM_DRIVE_EVIDENCE, 'result.json')));
    assert.ok(existsSync(join(env.FM_DRIVE_EVIDENCE, 'captain.log')));
    assert.ok(existsSync(join(env.FM_DRIVE_EVIDENCE, 'home', 'data', 'projects.md')), 'the home was archived');
    assert.ok(!existsSync(join(env.HOME, '.claude.json')), 'the throwaway config does not mutate ~/.claude.json');
    assert.ok(state.claudeConfigDir, 'the pane received CLAUDE_CONFIG_DIR');
    const isolated = JSON.parse(readFileSync(join(env.FM_DRIVE_EVIDENCE, 'claude-config', '.claude.json'), 'utf8'));
    assert.equal(isolated.hasCompletedOnboarding, true);
    assert.equal(isolated.bypassPermissionsModeAccepted, true);
    assert.equal(Object.values(isolated.projects)[0].hasTrustDialogAccepted, true);
    const theme = JSON.parse(readFileSync(join(env.FM_DRIVE_EVIDENCE, 'claude-config', 'settings.json'), 'utf8'));
    assert.equal(theme.theme, 'dark');
    const calls = readFileSync(join(dir, 'calls.log'), 'utf8').trim().split('\n');
    assert.equal(calls.length, j.overhead.herdrSpawns, 'the driver counted every herdr process it started');
  });

  const registerTrace = (feature) => ({
    feature,
    steps: [{ say: 'ahoy! add my project from {{projectOrigin}} as greeter', until: 'projects.registered:greeter', budgetSec: 10 }],
  });
  const captainSays = (state) => state.sends
    .filter((s) => s.text !== undefined && !/claude --dangerously|^\/exit$/.test(s.text))
    .map((s) => s.text);

  test('a result names its trace, the rows it proves, the code it drove and the home health, and record flips those rows', () => {
    const tsvRel = '.agents/skills/verify-firstmate/behaviors.tsv';
    const header = 'id\tsource\tbehavior\tstatus\tref\tevidence';
    const traceRel = 'tools/fm-drive/traces/e2e-proves.json';
    const recRoot = makeRoot({
      [tsvRel]: `${header}\nrow-register\treadme:features\tregisters a project\tunproven\t#83\t\n`,
      [traceRel]: JSON.stringify({ ...registerTrace('e2e-proves'), proves: { 'row-register': 1 } }),
    });
    const origin = tmp('origin');
    const g = (cwd, ...a) => {
      const r = spawnSync('git', ['-C', cwd, ...a], { encoding: 'utf8' });
      assert.equal(r.status, 0, `git ${a.join(' ')}: ${r.stderr}`);
      return r.stdout.trim();
    };
    g(origin, 'init', '-q', '--bare', '-b', 'main');
    g(recRoot, 'remote', 'add', 'origin', origin);
    g(recRoot, 'push', '-q', 'origin', 'main');
    g(recRoot, 'fetch', '-q', 'origin');
    const sha = g(recRoot, 'rev-parse', 'HEAD');

    const { env } = fakeEnv({ FM_DRIVE_ROOT: recRoot, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run') });
    const r = runDrive(['run', join(recRoot, traceRel)], env);
    assert.equal(r.status, 0, `stdout: ${r.stdout}\nstderr: ${r.stderr}`);
    assert.equal(r.json.trace, 'e2e-proves');
    assert.deepEqual(r.json.proves, { 'row-register': 1 });
    assert.deepEqual(r.json.code, { sha, dirty: false });
    assert.deepEqual(r.json.health, { until: 'home.clean && tabs.clean && wake.empty', ok: true, reason: 'holds' });

    const rec = runDrive(['record', join(env.FM_DRIVE_EVIDENCE, 'result.json')], env);
    assert.equal(rec.status, 0, rec.stderr);
    assert.equal(readFileSync(join(recRoot, tsvRel), 'utf8'),
      `${header}\nrow-register\treadme:features\tregisters a project\tproven\te2e-proves\t${sha} held through step 1, health clean; ${env.FM_DRIVE_EVIDENCE}\n`);
  });

  test('a driven home keeps the repo hooks, gets no captain.md, and reports its fidelity', () => {
    const { dir, env } = fakeEnv({
      FM_DRIVE_ROOT: root,
      FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'),
      FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run'),
      FM_DRIVE_KEEP: '1',
      FM_DRIVE_MODEL: 'opus',
    });
    const r = runDrive(['run', writeTrace(tmp('trace'), registerTrace('e2e-fidelity'))], env);
    const state = JSON.parse(readFileSync(join(dir, 'state.json'), 'utf8'));
    if (state.primary) { try { process.kill(state.primary.pid); } catch {} }
    scratch.push(dirname(state.home));
    const committed = spawnSync('git', ['-C', root, 'show', 'HEAD:.claude/settings.json']).stdout;
    assert.deepEqual(
      {
        exit: r.status,
        hooksAreTheRepos: readFileSync(join(state.home, '.claude', 'settings.json')).equals(committed),
        captainMdExists: existsSync(join(state.home, 'data', 'captain.md')),
        configBesideHome: dirname(state.claudeConfigDir) === dirname(state.home),
        fidelity: r.json?.fidelity,
        fidelityAtClose: r.json?.fidelityAtClose,
      },
      {
        exit: 0,
        hooksAreTheRepos: true,
        captainMdExists: false,
        configBesideHome: true,
        fidelity: { claudeConfig: 'clean', hooks: 'repo', captainMd: 'untouched', model: 'opus' },
        fidelityAtClose: { hooks: 'repo', captainMd: 'untouched' },
      },
      r.stderr,
    );
  });

  const launchesOf = (dir) => (existsSync(join(dir, 'state.json')) ? JSON.parse(readFileSync(join(dir, 'state.json'), 'utf8')).launches ?? 0 : 0);

  test('a clone that already holds a captain.md fails fidelity with exit 3 before claude launches', () => {
    const withCaptain = makeRoot({ 'data/captain.md': '# Captain\n' });
    const { dir, env } = fakeEnv({ FM_DRIVE_ROOT: withCaptain, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run') });
    const r = runDrive(['run', writeTrace(tmp('trace'), registerTrace('e2e-captain-md'))], env);
    assert.deepEqual(
      { exit: r.status, captainMd: r.json?.fidelity?.captainMd, named: /captainMd/.test(r.json?.error ?? ''), launches: launchesOf(dir) },
      { exit: 3, captainMd: 'present', named: true, launches: 0 },
      r.stderr,
    );
  });

  test('a clone whose hooks differ from the committed ones fails fidelity with exit 3 before claude launches', () => {
    const dirty = makeRoot();
    writeFileSync(join(dirty, '.claude', 'settings.json'), `${JSON.stringify({ hooks: {} }, null, 2)}\n`);
    const { dir, env } = fakeEnv({ FM_DRIVE_ROOT: dirty, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run') });
    const r = runDrive(['run', writeTrace(tmp('trace'), registerTrace('e2e-hooks'))], env);
    assert.deepEqual(
      { exit: r.status, hooks: r.json?.fidelity?.hooks, named: /hooks/.test(r.json?.error ?? ''), launches: launchesOf(dir) },
      { exit: 3, hooks: 'modified', named: true, launches: 0 },
      r.stderr,
    );
  });

  test('a claim that already holds before its say fails that step as vacuous, and the say is never typed', () => {
    const { dir, env } = fakeEnv({ FM_DRIVE_ROOT: root, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run') });
    const trace = {
      feature: 'e2e-vacuous',
      steps: [
        { say: 'ahoy! add my project from {{projectOrigin}} as greeter', until: 'projects.registered:greeter', budgetSec: 10 },
        { say: 'say hello to greeter', until: 'projects.registered:greeter', budgetSec: 10 },
      ],
    };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    const state = JSON.parse(readFileSync(join(dir, 'state.json'), 'utf8'));
    assert.deepEqual(
      {
        exit: r.status,
        pass: r.json?.pass,
        oks: r.json?.steps.map((s) => s.ok),
        vacuous: r.json?.steps[1]?.vacuous,
        why: /already held before its say/.test(r.json?.steps[1]?.reason ?? ''),
        typed: captainSays(state).filter((t) => t === 'say hello to greeter').length,
      },
      { exit: 1, pass: false, oks: [true, false], vacuous: true, why: true, typed: 0 },
      r.stderr,
    );
  });

  test('a captain.md written after the fidelity check but before any say fails the run at close', () => {
    const { dir, env } = fakeEnv({ FM_DRIVE_ROOT: root, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run') });
    const inject = join(tmp('inject'), 'open-writes-captain.mjs');
    writeFileSync(inject, [
      `import { Session } from ${JSON.stringify(pathToFileURL(join(HERE, '..', 'lib', 'session.mjs')).href)};`,
      "import { mkdirSync, writeFileSync } from 'node:fs';",
      'const open = Session.prototype.open;',
      "Session.prototype.open = async function () { mkdirSync(`${this.home}/data`, { recursive: true }); writeFileSync(`${this.home}/data/captain.md`, '# Captain'); return open.call(this); };",
    ].join('\n'));
    const r = spawnSync(NODE, ['--import', pathToFileURL(inject).href, DRIVE, 'run', writeTrace(tmp('trace'), registerTrace('e2e-late-captain'))], { env, encoding: 'utf8', timeout: 120_000 });
    const json = JSON.parse(r.stdout.trim().split('\n').at(-1));
    assert.deepEqual(
      { exit: r.status, pass: json.pass, before: json.fidelity?.captainMd, atClose: json.fidelityAtClose?.captainMd, named: /captainMd/.test(json.error ?? '') },
      { exit: 3, pass: false, before: 'untouched', atClose: 'present', named: true },
      r.stderr,
    );
    assert.ok(launchesOf(dir) >= 1);
  });

  test('hooks rewritten during the run fail it at close', () => {
    const { env } = fakeEnv({ FM_DRIVE_ROOT: root, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run') });
    const trace = { feature: 'e2e-hooks-late', steps: [{ say: 'rewrite the hooks for greeter', until: 'projects.registered:greeter', budgetSec: 10 }] };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    assert.deepEqual(
      { exit: r.status, pass: r.json?.pass, stepOk: r.json?.steps[0]?.ok, atClose: r.json?.fidelityAtClose?.hooks, named: /hooks/.test(r.json?.error ?? '') },
      { exit: 3, pass: false, stepOk: true, atClose: 'modified', named: true },
      r.stderr,
    );
  });

  test('a captain.md the primary writes after a say is reported, not failed', () => {
    const { env } = fakeEnv({ FM_DRIVE_ROOT: root, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run') });
    const trace = { feature: 'e2e-preference', steps: [{ say: 'remember that I prefer opus workers, and register greeter', until: 'projects.registered:greeter', budgetSec: 10 }] };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    assert.deepEqual(
      { exit: r.status, pass: r.json?.pass, fidelityAtClose: r.json?.fidelityAtClose },
      { exit: 0, pass: true, fidelityAtClose: { hooks: 'repo', captainMd: 'written-after-say' } },
      r.stderr,
    );
  });

  for (const claim of ['home.clean', 'wake.empty', 'file.contains:AGENTS.md:test root']) {
    test(`an empty say whose claim ${claim} held before the say it waits on fails as vacuous`, () => {
      const { env } = fakeEnv({ FM_DRIVE_ROOT: root, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run') });
      const trace = { feature: 'e2e-empty-vacuous', steps: [registerTrace('x').steps[0], { say: '', until: claim, budgetSec: 10 }] };
      const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
      assert.deepEqual(
        { exit: r.status, pass: r.json?.pass, oks: r.json?.steps.map((s) => s.ok), vacuous: r.json?.steps[1]?.vacuous, why: /already held before/.test(r.json?.steps[1]?.reason ?? '') },
        { exit: 1, pass: false, oks: [true, false], vacuous: true, why: true },
        r.stderr,
      );
    });
  }

  test('a leading empty say whose claim held before launch fails as vacuous', () => {
    const { env } = fakeEnv({ FM_DRIVE_ROOT: root, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run') });
    const trace = { feature: 'e2e-lead-vacuous', steps: [{ say: '', until: 'file.contains:AGENTS.md:test root', budgetSec: 10 }, registerTrace('x').steps[0]] };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    assert.deepEqual(
      { exit: r.status, pass: r.json?.pass, vacuous: r.json?.steps[0]?.vacuous, why: /already held before/.test(r.json?.steps[0]?.reason ?? '') },
      { exit: 1, pass: false, vacuous: true, why: true },
      r.stderr,
    );
  });

  test('an empty say waits without typing', () => {
    const { dir, env } = fakeEnv({ FM_DRIVE_ROOT: root, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run') });
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
    const { env } = fakeEnv({ FM_DRIVE_ROOT: root, FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'), FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run') });
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
    const { env } = fakeEnv({ FM_DRIVE_ROOT: root, FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run') });
    const trace = { feature: 'e2e-timeout', steps: [{ say: 'do nothing', until: 'tasks.count>=1', budgetSec: 1.5 }] };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    assert.equal(r.status, 1, r.stderr);
    assert.equal(r.json.pass, false);
    assert.match(r.json.steps[0].reason, /not within/);
    assert.ok(r.json.steps[0].ms >= 1400 && r.json.steps[0].ms < 4000, `budget honoured (${r.json.steps[0].ms} ms)`);
  });

  test('the shipped restart-primary trace passes against the fake, and the run is cheap', () => {
    const { dir, env } = fakeEnv({ FM_DRIVE_ROOT: root, FAKE_HERDR_SCRIPT: join(FIXTURES, 'restart-primary-script.json'), FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run') });
    const r = runDrive(['run', join(HERE, '..', 'traces', 'restart-primary.json')], env);
    assert.equal(r.status, 0, `stdout: ${r.stdout}\nstderr: ${r.stderr}`);
    const j = r.json;
    assert.equal(j.pass, true);
    assert.equal(j.steps.length, 5);
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
    const { dir, env } = fakeEnv({ FM_DRIVE_ROOT: root });
    const r = runDrive(['run', join(FIXTURES, 'reject', 'lock-only.json')], env);
    assert.equal(r.status, 2);
    assert.ok(!existsSync(join(dir, 'calls.log')));
  });

  test('first say waits for a delayed lock when the pane shows session-start', () => {
    const { dir, env } = fakeEnv({
      FM_DRIVE_ROOT: root,
      FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'),
      FAKE_HERDR_LOCK_DELAY_MS: '2500',
      FAKE_HERDR_PANE_UNTIL_LOCK: 'bypass permissions on\nRunning Bash: bin/fm-session-start.sh\n',
      FM_DRIVE_OPERABLE_MS: '15000',
      FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run'),
    });
    const trace = {
      feature: 'e2e-operable-wait',
      steps: [{ say: 'ahoy! add my project from {{projectOrigin}} as greeter', until: 'projects.registered:greeter', budgetSec: 10 }],
    };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.json.pass, true);
    const state = JSON.parse(readFileSync(join(dir, 'state.json'), 'utf8'));
    const firstSay = state.sends.find((s) => s.text && s.text.startsWith('ahoy! add my project'));
    assert.ok(firstSay, 'the first captain say was typed');
    assert.ok(state.lockAt, 'the fake recorded when the lock appeared');
    assert.ok(firstSay.t >= state.lockAt, `say ${firstSay.t} was after lock ${state.lockAt}`);
    assert.ok(r.json.operableMs >= 1500, `operable wait ${r.json.operableMs} ms`);
  });

  test('a claude that takes a few seconds to reach the foreground is not counted as exited', () => {
    const { dir, env } = fakeEnv({
      FM_DRIVE_ROOT: root,
      FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'),
      FAKE_HERDR_CLAUDE_START_CALLS: '3',
      FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run'),
    });
    const r = runDrive(['run', writeTrace(tmp('trace'), registerTrace('e2e-slow-start'))], env);
    assert.equal(r.status, 0, `stdout: ${r.stdout}\nstderr: ${r.stderr}`);
    assert.equal(r.json.pass, true);
    const state = JSON.parse(readFileSync(join(dir, 'state.json'), 'utf8'));
    assert.equal(state.startingCalls, 0, 'the driver kept asking until claude reached the foreground');
    assert.equal(state.launches, 1, 'one launch, no retry');
    const says = captainSays(state);
    assert.equal(says.length, 1);
    assert.match(says[0], /^ahoy! add my project from \S+ as greeter$/);
  });

  test('a persistent-cd session-start denial does not send Escape', () => {
    const { dir, env } = fakeEnv({
      FM_DRIVE_ROOT: root,
      FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'),
      FAKE_HERDR_STATUS: 'blocked',
      FAKE_HERDR_PANE: 'bypass permissions on\nBash: cd /tmp/home && bin/fm-session-start.sh\nDenied by persistent-cd hook\n',
      FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run'),
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
      FM_DRIVE_ROOT: root,
      FAKE_HERDR_SCRIPT: join(FIXTURES, 'e2e-script.json'),
      FAKE_HERDR_TRUST: '1',
      FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run'),
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
      FM_DRIVE_ROOT: root,
      FAKE_HERDR_PANE: ' ❯ No, exit\n   Yes, I trust this folder\n',
      FM_DRIVE_TRUST_MS: '2500',
      FM_DRIVE_READY_MS: '20000',
      FM_DRIVE_EVIDENCE: join(tmp('evidence'), 'run'),
    });
    const trace = { feature: 'e2e-trust-stuck', steps: [{ say: 'ahoy', until: 'projects.registered:greeter', budgetSec: 60 }] };
    const r = runDrive(['run', writeTrace(tmp('trace'), trace)], env);
    assert.equal(r.status, 3, r.stderr);
    assert.match(r.json.error, /folder trust/);
    assert.equal(r.json.readyMs, null, 'ready must not fire while trust is up');
    assert.ok(r.json.wallMs < (process.platform === 'win32' ? 90_000 : 30_000), `failed inside the bound (${r.json.wallMs} ms)`);
  });
});

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
    const dir = prepareClaudeConfig(join(tmp('scratch'), 'claude-config'), home, { HOME: userHome, USERPROFILE: userHome });
    assert.ok(existsSync(join(dir, '.claude.json')));
    assert.deepEqual(readdirSync(home), [], 'nothing is written into the home');
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
    const dir = prepareClaudeConfig(join(tmp('scratch'), 'claude-config'), home, { HOME: userHome, USERPROFILE: userHome });
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
    const dir = prepareClaudeConfig(join(tmp('scratch'), 'claude-config'), home, { HOME: userHome, USERPROFILE: userHome });
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

  test('fidelity measures the throwaway config and names what the driver did not write', async () => {
    const home = makeRoot();
    const userHome = tmp('user-home');
    const env = { ...process.env, HOME: userHome, USERPROFILE: userHome, CLAUDE_CONFIG_DIR: '' };
    const s = new sessionLib.Session({ trace: { feature: 'cfg', steps: [] }, env });
    s.home = home;
    s.claudeConfigDir = prepareClaudeConfig(join(tmp('scratch'), 'claude-config'), home, env);
    const clean = (await s.fidelity()).claudeConfig;
    writeFileSync(join(s.claudeConfigDir, 'CLAUDE.md'), '# host memory\n');
    const settings = JSON.parse(readFileSync(join(s.claudeConfigDir, 'settings.json'), 'utf8'));
    writeFileSync(join(s.claudeConfigDir, 'settings.json'), JSON.stringify({ ...settings, hooks: { Stop: [] } }));
    const leaked = (await s.fidelity()).claudeConfig;
    assert.deepEqual({ clean, leaked }, { clean: 'clean', leaked: 'carries CLAUDE.md, settings.json:hooks' });
  });

  test('a shell prompt read before a launch does not mark the launched primary dead', async () => {
    let release;
    const heldRead = new Promise((r) => { release = r; });
    const s = new sessionLib.Session({ trace: { feature: 'race', steps: [] }, env: process.env });
    s.paneId = 'p1';
    s.home = '/home/captain/firstmate';
    s.claudeConfigDir = '/home/captain/claude-config';
    s.herdr = {
      subscribe: () => null,
      call: async (method) => {
        if (method === 'pane.get') return { pane: { agent_status: 'unknown' } };
        if (method === 'pane.read') { await heldRead; return { read: { text: 'user@host MINGW64 ~\n$ ' } }; }
        return {};
      },
    };
    s.awaitReady = async () => {};
    s.watchDialogs = () => {};
    s.watchPrimaryStatus();
    try {
      await new Promise((r) => setImmediate(r));
      await s.launch();
      release();
      await new Promise((r) => setImmediate(r));
    } finally {
      clearInterval(s.statusPoll);
    }
    assert.equal(s.signals.shellDead, null);
  });

  test('a shell prompt read while claude is still starting does not mark the primary dead', async () => {
    let release;
    const heldRead = new Promise((r) => { release = r; });
    const s = new sessionLib.Session({ trace: { feature: 'race', steps: [] }, env: process.env });
    s.paneId = 'p1';
    s.home = '/home/captain/firstmate';
    s.claudeConfigDir = '/home/captain/claude-config';
    s.herdr = {
      subscribe: () => null,
      call: async (method) => {
        if (method === 'pane.get') return { pane: { agent_status: 'unknown' } };
        if (method === 'pane.read') { await heldRead; return { read: { text: 'user@host MINGW64 ~\n$ ' } }; }
        return {};
      },
    };
    s.awaitReady = async () => {
      s.watchPrimaryStatus();
      await new Promise((r) => setImmediate(r));
    };
    s.watchDialogs = () => {};
    try {
      await s.launch();
      release();
      await new Promise((r) => setImmediate(r));
    } finally {
      clearInterval(s.statusPoll);
    }
    assert.equal(s.signals.shellDead, null);
  });

  test('a relaunch is not read as exited from the previous launch line still on screen', async () => {
    const before = [
      "$ export CLAUDE_CONFIG_DIR='C:\\x\\claude-config'; cd \"$(cygpath -u 'C:\\x\\firstmate')\" && claude --dangerously-skip-permissions --model opus",
      'Resume this session with:',
      'claude --resume 95c1f663-0cc5-473c-bfcf-8434826424ee',
      'user@host MINGW64 /tmp/x/firstmate',
      '$ ',
    ].join('\n');
    let reads = 0;
    let typed = '';
    const s = new sessionLib.Session({ trace: { feature: 'relaunch', steps: [] }, env: process.env });
    s.paneId = 'p1';
    s.shell = 'git-bash';
    s.home = tmp('relaunch-home');
    s.claudeConfigDir = 'C:\\x\\claude-config';
    s.readyMs = 20_000;
    s.herdr = {
      call: async (method, params) => {
        if (method === 'pane.send_input') typed = params.text;
        if (method === 'pane.read') {
          reads += 1;
          if (reads < 3) return { read: { text: before } };
          if (reads < 5) return { read: { text: `${before}${typed}\n` } };
          return { read: { text: 'Claude Code\n⏵⏵ bypass permissions on (shift+tab to cycle)' } };
        }
        if (method === 'pane.process_info') {
          return { process_info: { foreground_processes: [{ name: reads < 5 ? 'bash.exe' : 'claude.exe', pid: 4242 }] } };
        }
        return {};
      },
    };
    s.watchDialogs = () => {};
    await s.launch();
    assert.equal(s.primaryPid, 4242);
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

});

function listTree(dir, prefix = '') {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const rel = prefix ? `${prefix}/${e.name}` : e.name;
    return e.isDirectory() ? [rel, ...listTree(join(dir, e.name), rel)] : [rel];
  }).sort();
}

// Git for Windows' own bash, so the recorded pid is an MSYS pid as fm-watch.sh writes it.
const BASH = process.platform === 'win32' ? 'C:/Program Files/Git/usr/bin/bash.exe' : 'bash';

describe('close', () => {
  test('the evidence copy skips entries that vanish mid-walk and keeps the rest', () => {
    const src = tmp('copy-src');
    const dst = join(tmp('copy-dst'), 'state');
    writeFileSync(join(src, 'a'), 'A');
    writeFileSync(join(src, 'b'), 'B');
    mkdirSync(join(src, 'd'));
    writeFileSync(join(src, 'd', 'x'), 'X');
    mkdirSync(join(src, '.x.lock.owner.1'));
    writeFileSync(join(src, '.x.lock.owner.1', 'pid'), '1');
    const vanish = new Set(['b', '.x.lock.owner.1']);
    sessionLib.copyTreeBestEffort(src, dst, {
      beforeEntry: (rel) => { if (vanish.has(rel)) rmSync(join(src, rel), { recursive: true, force: true }); },
    });
    assert.deepEqual(listTree(dst), ['a', 'd', 'd/x']);
    assert.equal(readFileSync(join(dst, 'a'), 'utf8'), 'A');
    assert.equal(readFileSync(join(dst, 'd', 'x'), 'utf8'), 'X');
  });

  test('archiving a home whose watcher churns lock dirs does not kill the driver', () => {
    const home = tmp('churn-home');
    const state = join(home, 'state');
    mkdirSync(state);
    for (let i = 0; i < 30; i++) writeFileSync(join(state, `t${i}.status`), 'working: x\n');
    const churn = spawn(NODE, ['-e', `
      const { mkdirSync, rmSync, writeFileSync } = require('node:fs');
      const d = process.argv[1];
      for (;;) for (let i = 0; i < 50; i++) { const p = d + '/.watch.lock.owner.' + i; try { mkdirSync(p); writeFileSync(p + '/pid', '1'); rmSync(p, { recursive: true, force: true }); } catch {} }
    `, state], { stdio: 'ignore' });
    try {
      const script = join(tmp('churn-script'), 'archive.mjs');
      writeFileSync(script, `
        import { Session } from ${JSON.stringify(pathToFileURL(join(HERE, '..', 'lib', 'session.mjs')).href)};
        const s = new Session({ trace: { feature: 'churn', steps: [] }, env: { ...process.env, FM_DRIVE_EVIDENCE: process.argv[3] } });
        s.home = process.argv[2];
        for (let n = 0; n < 200; n++) s.archive();
        console.log('survived');
      `);
      const r = spawnSync(NODE, [script, home, join(tmp('churn-evidence'), 'run')], { encoding: 'utf8', timeout: 120_000 });
      assert.deepEqual({ status: r.status, out: r.stdout.trim() }, { status: 0, out: 'survived' }, r.stderr);
    } finally {
      churn.kill();
    }
  });

  test('stopWatcher stops the pid the watcher recorded, including an MSYS pid on Windows', async () => {
    const home = tmp('watcher-home');
    const lock = join(home, 'state', '.watch.lock');
    mkdirSync(lock, { recursive: true });
    const pidFile = join(lock, 'pid').replace(/\\/g, '/');
    const watcher = spawn(BASH, ['-c', 'echo $$ > "$1"; while :; do sleep 1; done', 'watcher', pidFile], { stdio: 'ignore' });
    const exited = new Promise((res) => watcher.once('exit', () => res(true)));
    try {
      for (let i = 0; i < 100 && !existsSync(pidFile); i++) await new Promise((r) => setTimeout(r, 100));
      assert.ok(existsSync(pidFile), 'the stand-in watcher recorded its pid');
      const evidence = join(tmp('watcher-evidence'), 'run');
      const s = new sessionLib.Session({ trace: { feature: 'watcher', steps: [] }, env: { ...process.env, FM_DRIVE_EVIDENCE: evidence } });
      mkdirSync(evidence, { recursive: true });
      s.home = home;
      await s.stopWatcher();
      const gone = await Promise.race([exited, new Promise((r) => setTimeout(() => r(false), 5000))]);
      assert.equal(gone, true, 'the watcher process exited');
      assert.match(readFileSync(join(evidence, 'watcher.txt'), 'utf8'), /^pid \d+ stopped\n$/);
    } finally {
      watcher.kill();
    }
  });
});

test('no module spawns a shell', () => {
  for (const f of ['drive.mjs', 'lib/herdr.mjs', 'lib/session.mjs', 'lib/wait.mjs']) {
    const src = readFileSync(join(HERE, '..', f), 'utf8');
    assert.ok(!/shell:\s*true/.test(src), `${f} never spawns through a shell`);
    assert.ok(!/execSync|exec\(/.test(src), `${f} never uses exec`);
  }
});

describe('repo checkout', () => {
  test('a clone made with core.autocrlf=true, the Git for Windows default, checks every file out with LF', () => {
    const dest = join(tmp('autocrlf'), 'home');
    const clone = spawnSync('git', ['clone', '-q', '-c', 'core.autocrlf=true', REPO, dest], { encoding: 'utf8' });
    assert.equal(clone.status, 0, clone.stderr);
    const eol = spawnSync('git', ['-C', dest, 'ls-files', '--eol'], { encoding: 'utf8' }).stdout;
    const crlf = eol.split('\n').filter((line) => /\bw\/crlf\b/.test(line)).map((line) => line.split('\t').pop());
    assert.deepEqual(crlf, []);
  });
});
