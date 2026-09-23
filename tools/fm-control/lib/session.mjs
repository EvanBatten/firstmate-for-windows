// One firstmate session under test: a throwaway home, one herdr pane the
// driver owns, a real primary started from that pane's own shell, captain
// lines typed into it, and a close that touches only what this run created.
//
// The pane shell is whatever herdr gives the pane (bash here, pwsh on the
// operator's Windows host); claude starts as its child with no Git Bash login
// hop. PATH reaches the pane as FM_PANE_PATH and the launch line adopts it,
// because herdr may drop a PATH passed through workspace env.
//
// Ready is a process fact plus a firstmate fact: herdr's pane.process_info
// lists a claude foreground process, and either state/.lock exists in the
// home under a new identity or the prompt is up (see awaitReady). Liveness
// afterwards is kill(pid, 0) on that pid, which costs no herdr call. Claude's
// first-run dialogs are skipped by writing a throwaway CLAUDE_CONFIG_DIR
// (onboarding, bypass-permissions, folder trust, project onboarding, theme)
// and passing it into the pane env. The throwaway home also gets a captain.md
// that tells firstmate not to park on missing-tool installs. ~/.claude.json
// is never mutated. Dialog handlers remain as a fallback; a later parked
// question is answered from BLOCKED_ANSWERS or fails the step at once with
// the pane excerpt. A dead primary is the pid going away or the pane
// returning to a shell prompt (`$`, `firstmate $`, `PS C:\path>`, `C:\path>`).
//
// Environment:
//   FM_CONTROL_MODEL        primary model (default opus)
//   FM_CONTROL_READY_MS     ready budget per launch (default 120000)
//   FM_CONTROL_UNTIL_MS     default step budget when a step has no budgetSec (default 180000)
//   FM_CONTROL_EVIDENCE     evidence directory (default <tmp>/fm-control-artifacts/<feature>-<utc>)
//   FM_CONTROL_KEEP         1 keeps the throwaway home and pane after the run
//   FM_CONTROL_PRETRUST     0 skips writing the throwaway CLAUDE_CONFIG_DIR
//   FM_CONTROL_ROOT         checkout to clone as the home (default: the repo holding this file)
//   CLAUDE_CODE_OAUTH_TOKEN / CLAUDE_CODE_OATH_TOKEN  passed to the pane as CLAUDE_CODE_OAUTH_TOKEN; never logged

import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, appendFileSync, existsSync, rmSync, cpSync, readdirSync, symlinkSync, realpathSync, lstatSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join, dirname, resolve, delimiter, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { Herdr, HerdrError, atShellPrompt, sleep } from './herdr.mjs';
import { recordedPaneIds } from './predicates.mjs';

// Isolated Claude config for one throwaway home. Never writes ~/.claude.json.
export function prepareClaudeConfig(home) {
  const config = join(home, '.fm-control-claude');
  mkdirSync(config, { recursive: true });
  writeFileSync(
    join(config, '.claude.json'),
    `${JSON.stringify({
      hasCompletedOnboarding: true,
      bypassPermissionsModeAccepted: true,
      hasAcknowledgedCostThreshold: true,
      projects: {
        [home]: { hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true },
      },
    })}\n`,
    { mode: 0o600 },
  );
  writeFileSync(
    join(config, 'settings.json'),
    `${JSON.stringify({ theme: 'dark' })}\n`,
    { mode: 0o600 },
  );
  return config;
}

// Closed catalog of parked firstmate-setup questions the driver may answer.
// Anything else fails the step immediately with the pane excerpt.
export const BLOCKED_ANSWERS = [
  {
    name: 'tool-install',
    match: /MISSING:\s*\S+|which tools? (?:should I |to )?install|install (?:treehouse|no-mistakes|gh-axi|chrome-devtools-axi|lavish-axi|tasks-axi|quota-axi)|tools? (?:are|is) missing/i,
    answer: 'None. Do not install any tools. Missing tools are not a blocker. Continue the work I already gave you.',
  },
];

export function matchBlockedAnswer(text) {
  const t = String(text || '');
  return BLOCKED_ANSWERS.find((entry) => entry.match.test(t)) ?? null;
}

export const THROWAWAY_CAPTAIN = `# Captain

This is a throwaway measurement home.

Missing bootstrap tools (treehouse, no-mistakes, gh-axi, chrome-devtools-axi, lavish-axi, tasks-axi, quota-axi) are not a blocker.
Do not ask which tools to install.
Do not park on a tool-install or onboarding question.
Continue the assigned work with the tools already on PATH.
`;

export function seedThrowawayHome(home) {
  mkdirSync(join(home, 'data'), { recursive: true });
  writeFileSync(join(home, 'data', 'captain.md'), THROWAWAY_CAPTAIN);
}

const HERE = dirname(fileURLToPath(import.meta.url));
export const DEFAULT_ROOT = resolve(HERE, '..', '..', '..');

export class Session {
  constructor({ trace, env = process.env, log = () => {} }) {
    this.trace = trace;
    this.env = env;
    this.log = log;
    this.model = env.FM_CONTROL_MODEL || 'opus';
    this.readyMs = Number.parseInt(env.FM_CONTROL_READY_MS || '120000', 10);
    if (!this.env.CLAUDE_CODE_OAUTH_TOKEN && this.env.CLAUDE_CODE_OATH_TOKEN) {
      this.env = { ...this.env, CLAUDE_CODE_OAUTH_TOKEN: this.env.CLAUDE_CODE_OATH_TOKEN };
    }
    this.root = env.FM_CONTROL_ROOT || DEFAULT_ROOT;
    this.scratch = null;
    this.home = null;
    this.herdr = null;
    this.workspaceId = null;
    this.paneId = null;
    this.shell = 'bash';
    this.primaryPid = null;
    this.lockBaseline = undefined;
    this.seeds = {};
    this.projectOrigin = null;
    this.seenTaskIds = new Set();
    this.taskTmps = new Set();
    this.baselineWorkspaces = new Set();
    this.signals = { blocked: null, status: null, shellDead: null };
    this.answeredBlocked = new Set();
    this.answeringBlocked = false;
    this.claudeConfigDir = null;
    this.statusPoll = null;
    this.counters = { gitSpawns: 0, setupSpawns: 0, cleanupSpawns: 0 };
    this.captainLog = [];
    this.closed = false;
    const stamp = new Date().toISOString().replace(/[:.]/g, '').slice(0, 15);
    this.evidenceDir = env.FM_CONTROL_EVIDENCE || join(tmpdir(), 'fm-control-artifacts', `${trace.feature}-${stamp}`);
  }

  // ---- setup --------------------------------------------------------------

  async open() {
    mkdirSync(this.evidenceDir, { recursive: true });
    this.scratch = mkdtempSync(join(tmpdir(), `fm-control-${this.trace.feature}-`));
    this.home = join(this.scratch, 'firstmate');
    await this.cloneHome();
    if (this.trace.steps.some((s) => s.say.includes('{{projectOrigin}}'))) {
      await this.seedProject(this.trace.project || 'greeter');
    }
    seedThrowawayHome(this.home);
    if (this.env.FM_CONTROL_PRETRUST !== '0') this.claudeConfigDir = prepareClaudeConfig(this.home);
    this.herdr = await Herdr.attach(this.env, { log: this.log });
    try {
      const list = await this.herdr.call('workspace.list');
      for (const w of list.workspaces ?? []) this.baselineWorkspaces.add(w.workspace_id);
    } catch {
      // a baseline is a courtesy for cleanup; its absence closes nothing extra
    }
    // TMUX is blanked so a herdr server that happens to run under tmux still
    // yields a pane where firstmate auto-detects herdr, not tmux.
    const paneEnv = { FM_PANE_PATH: this.panePath(), PATH: this.panePath(), TMUX: '', TMUX_PANE: '' };
    if (this.claudeConfigDir) paneEnv.CLAUDE_CONFIG_DIR = this.claudeConfigDir;
    const token = this.env.CLAUDE_CODE_OAUTH_TOKEN || this.env.CLAUDE_CODE_OATH_TOKEN || '';
    if (token) paneEnv.CLAUDE_CODE_OAUTH_TOKEN = token;
    const created = await this.herdr.call('workspace.create', { cwd: this.home, label: `fm-control-${this.trace.feature}`, focus: false, env: paneEnv });
    this.workspaceId = created.workspace?.workspace_id;
    this.paneId = created.root_pane?.pane_id;
    if (!this.workspaceId || !this.paneId) throw new HerdrError('herdr created a workspace but reported no pane for it');
    this.keep('workspace.json', JSON.stringify({ workspace_id: this.workspaceId, pane_id: this.paneId, session: this.herdr.session, transport: this.herdr.transport }, null, 2));
    const info = await this.herdr.call('pane.process_info', { pane_id: this.paneId });
    const shellName = (info.process_info?.foreground_processes?.[0]?.name || '').toLowerCase();
    if (/pwsh|powershell/.test(shellName)) this.shell = 'pwsh';
    else if (shellName === 'cmd' || shellName === 'cmd.exe') this.shell = 'cmd';
    else this.shell = 'posix';
    this.watchPrimaryStatus();
  }

  panePath() {
    const parts = [join(this.home, '.tools', 'node_modules', '.bin')];
    if (this.env.FM_CONTROL_PANE_PATH_EXTRA) parts.push(this.env.FM_CONTROL_PANE_PATH_EXTRA);
    parts.push(this.env.PATH || '');
    return parts.filter(Boolean).join(delimiter);
  }

  async git(args, { cwd, quiet = true } = {}) {
    this.counters.setupSpawns += 1;
    return new Promise((resolvePromise, reject) => {
      const child = spawn('git', args, { cwd, stdio: ['ignore', 'pipe', 'pipe'], shell: false, windowsHide: true });
      let out = '';
      let err = '';
      child.stdout.on('data', (d) => { out += d; });
      child.stderr.on('data', (d) => { err += d; });
      child.on('error', reject);
      child.on('close', (code) => {
        if (code === 0) resolvePromise(out.trim());
        else reject(new Error(`git ${args.slice(0, 2).join(' ')} exited ${code}${quiet ? '' : `: ${err.trim()}`}`));
      });
    });
  }

  // The code under test, cloned into a fresh home: the same isolation rule as
  // tests/verification/session-lib.sh, so the primary never runs in the
  // primary checkout.
  async cloneHome() {
    const sha = await this.git(['-C', this.root, 'rev-parse', 'HEAD']);
    const branch = await this.git(['-C', this.root, 'rev-parse', '--abbrev-ref', 'HEAD']);
    if (branch === 'HEAD') {
      await this.git(['clone', '-q', '-c', 'core.symlinks=true', this.root, this.home]);
      await this.git(['-C', this.home, 'checkout', '-q', sha]);
    } else {
      await this.git(['clone', '-q', '-c', 'core.symlinks=true', '--branch', branch, this.root, this.home]);
    }
    const dirty = await this.git(['-C', this.root, 'status', '--porcelain']);
    if (dirty) {
      try {
        const patch = await new Promise((res, rej) => {
          this.counters.setupSpawns += 1;
          const c = spawn('git', ['-C', this.root, 'diff', 'HEAD', '--binary'], { stdio: ['ignore', 'pipe', 'ignore'], shell: false, windowsHide: true });
          const chunks = [];
          c.stdout.on('data', (d) => chunks.push(d));
          c.on('error', rej);
          c.on('close', () => res(Buffer.concat(chunks)));
        });
        if (patch.length) {
          await new Promise((res, rej) => {
            this.counters.setupSpawns += 1;
            const c = spawn('git', ['-C', this.home, 'apply'], { stdio: ['pipe', 'ignore', 'ignore'], shell: false, windowsHide: true });
            c.on('error', rej);
            c.on('close', (code) => (code === 0 ? res() : rej(new Error('apply failed'))));
            c.stdin.end(patch);
          });
          this.log('uncommitted changes from the checkout applied to the clone; untracked files are not');
        }
      } catch {
        this.log(`uncommitted changes could not be applied; the clone is ${sha} exactly`);
      }
    }
    const tools = this.env.FM_CONTROL_TOOLS_DIR || join(this.root, '.tools');
    if (existsSync(tools)) {
      try { symlinkSync(realpathSync(tools), join(this.home, '.tools'), 'dir'); } catch { cpSync(tools, join(this.home, '.tools'), { recursive: true }); }
    }
    const skills = join(this.home, '.claude', 'skills');
    try {
      if (!lstatSync(skills).isSymbolicLink() || !existsSync(skills)) throw new Error('unresolved');
    } catch {
      throw new HerdrError("the clone's harness skill link does not resolve, so the primary would have no skills");
    }
    this.keep('code.txt', `root ${this.root}\nbranch ${branch}\ncommit ${sha}\nhome ${this.home}\n${dirty ? `uncommitted:\n${dirty}\n` : ''}`);
  }

  // A throwaway project with its own bare origin and one commit on main, the
  // shape tests/verification/session-lib.sh's project_seed makes.
  async seedProject(name) {
    const origin = join(this.scratch, `${name}.git`);
    const seed = join(this.scratch, `${name}-seed`);
    await this.git(['init', '-q', '--bare', '-b', 'main', origin]);
    await this.git(['clone', '-q', origin, seed]);
    const cfg = (k, v) => this.git(['-C', seed, 'config', k, v]);
    await cfg('user.email', 'verify@example.invalid');
    await cfg('user.name', 'verification');
    await cfg('core.autocrlf', 'false');
    await this.git(['-C', seed, 'checkout', '-q', '-b', 'main']).catch(() => {});
    writeFileSync(join(seed, 'README.md'), `# ${name}\n\nA throwaway project for a firstmate control run.\n`);
    await this.git(['-C', seed, 'add', '-A']);
    await this.git(['-C', seed, 'commit', '-qm', `start the ${name} project`]);
    await this.git(['-C', seed, 'push', '-q', '-u', 'origin', 'main']);
    this.seeds[name] = await this.git(['-C', origin, 'rev-parse', 'main']);
    rmSync(seed, { recursive: true, force: true });
    this.projectOrigin = origin;
    this.projectName = name;
  }

  // ---- launch and ready ---------------------------------------------------

  launchLine() {
    const flags = `--dangerously-skip-permissions --model ${this.model}`;
    const home = this.home;
    const cfg = this.claudeConfigDir;
    if (this.shell === 'pwsh') {
      const cfgSet = cfg ? `; $env:CLAUDE_CONFIG_DIR = '${cfg.replace(/'/g, "''")}'` : '';
      return `if ($env:FM_PANE_PATH) { $env:Path = $env:FM_PANE_PATH }${cfgSet}; Set-Location '${home.replace(/'/g, "''")}'; claude ${flags}`;
    }
    if (this.shell === 'cmd') {
      const cfgSet = cfg ? `set "CLAUDE_CONFIG_DIR=${cfg}" && ` : '';
      return `set "PATH=%FM_PANE_PATH%" && ${cfgSet}cd /d "${home}" && claude ${flags}`;
    }
    const cfgSet = cfg ? `export CLAUDE_CONFIG_DIR='${cfg.replace(/'/g, "'\\''")}'; ` : '';
    return `export PATH="$FM_PANE_PATH"; ${cfgSet}cd '${home.replace(/'/g, "'\\''")}' && claude ${flags}`;
  }

  async launch() {
    const t0 = Date.now();
    this.primaryPid = null;
    this.signals.shellDead = null;
    await this.herdr.call('pane.send_input', { pane_id: this.paneId, text: this.launchLine(), keys: ['enter'] });
    await this.awaitReady();
    return Date.now() - t0;
  }

  async foreground() {
    const info = await this.herdr.call('pane.process_info', { pane_id: this.paneId });
    return info.process_info?.foreground_processes ?? [];
  }

  lockText() {
    try { return readFileSync(join(this.home, 'state', '.lock'), 'utf8').trim() || null; } catch { return null; }
  }

  async paneText(source = 'visible', lines) {
    const r = await this.herdr.call('pane.read', { pane_id: this.paneId, source, ...(lines ? { lines } : {}) });
    return r.read?.text ?? '';
  }

  async keys(...keys) {
    await this.herdr.call('pane.send_input', { pane_id: this.paneId, keys });
  }

  // Answer a claude dialog visible in the pane. Returns true when one was handled.
  async answerDialog(text) {
    const cursorOnNo = /❯\s*No/.test(text);
    if (/Yes, I trust this folder/.test(text)) {
      this.snapshot('trust-prompt', text);
      if (cursorOnNo) { await this.keys('down'); await sleep(250); }
      await this.keys('enter');
      return true;
    }
    if (/Yes, I accept/.test(text) && /[Bb]ypass [Pp]ermissions/.test(text)) {
      this.snapshot('bypass-prompt', text);
      if (cursorOnNo) { await this.keys('down'); await sleep(250); }
      await this.keys('enter');
      return true;
    }
    if (/Select login method/.test(text)) {
      this.snapshot('login-prompt', text);
      throw new HerdrError('claude opened its first-run login dialog in the pane; the throwaway CLAUDE_CONFIG_DIR did not skip onboarding (or CLAUDE_CODE_OAUTH_TOKEN is missing)');
    }
    if (/Light mode \(ANSI colors only\)/.test(text)) {
      this.snapshot('theme-prompt', text);
      await this.keys('enter');
      return true;
    }
    return false;
  }

  // A parked question: answer a known firstmate-setup prompt, or fail the
  // step immediately with the pane excerpt. One answer per catalog name per
  // launch; a repeat of the same question is a loop, not a second try.
  async handleBlockedQuestion() {
    if (this.answeringBlocked) return { handled: true, name: 'in-flight' };
    this.answeringBlocked = true;
    try {
      const text = await this.paneText().catch(() => '');
      this.snapshot('blocked-question', text);
      if (await this.answerDialog(text)) {
        this.signals.blocked = null;
        return { handled: true, name: 'dialog' };
      }
      const hit = matchBlockedAnswer(text);
      if (hit) {
        if (this.answeredBlocked.has(hit.name)) {
          return { handled: false, reason: `the primary asked the same ${hit.name} question again: ${lastLines(text)}` };
        }
        this.log(`answering a parked ${hit.name} question`);
        this.answeredBlocked.add(hit.name);
        await this.herdr.call('pane.send_input', { pane_id: this.paneId, text: hit.answer, keys: ['enter'] });
        this.signals.blocked = null;
        return { handled: true, name: hit.name };
      }
      return { handled: false, reason: `the primary stopped to ask a question: ${lastLines(text) || this.signals.blocked}` };
    } finally {
      this.answeringBlocked = false;
    }
  }

  // Ready is claude running as the pane's foreground process plus one of two
  // firstmate-side facts: the home's lock exists under a new identity (the
  // SessionStart hook took the helm, which it does once state/ exists), or
  // the prompt is up with its bypass footer (a fresh home, where the hook
  // stands down and the primary takes the helm on its first turn instead,
  // exactly as tests/verification/session-lib.sh treats it).
  async awaitReady() {
    const deadline = Date.now() + this.readyMs;
    let sawClaude = false;
    let tick = 0;
    while (Date.now() < deadline) {
      const lock = this.lockText();
      const lockFresh = lock !== null && lock !== this.lockBaseline;
      const text = await this.paneText();
      if (await this.answerDialog(text)) { await sleep(400); continue; }
      const prompted = /bypass permissions on/.test(text);
      if (atShellPrompt(text) && (sawClaude || /claude --dangerously/.test(text))) {
        this.snapshot('exited-before-ready', text);
        throw new HerdrError(`the primary exited before it was ready. Its pane shows: ${lastLines(text)}`);
      }
      // The process list is asked for only when it can decide something: a
      // ready candidate, or every third tick to notice an exit. On the cli
      // transport each ask is a process, so this halves the ready cost.
      if (lockFresh || prompted || tick % 3 === 0) {
        const fg = await this.foreground();
        const claude = fg.find((p) => /claude/i.test(p.name || '') || /claude/i.test(p.argv?.[0] || ''));
        if (claude) {
          sawClaude = true;
          if (lockFresh || prompted) {
            this.primaryPid = claude.pid;
            this.lockAtReady = lock;
            this.snapshot('ready', text);
            return;
          }
        } else if (sawClaude || /claude --dangerously/.test(text)) {
          this.snapshot('exited-before-ready', text);
          throw new HerdrError(`the primary exited before it was ready. Its pane shows: ${lastLines(text)}`);
        }
      }
      tick += 1;
      await sleep(1000);
    }
    const text = await this.paneText().catch(() => '');
    this.snapshot('not-ready', text);
    throw new HerdrError(`the primary did not become ready within ${Math.round(this.readyMs / 1000)} s. Its pane shows: ${lastLines(text)}`);
  }

  // ---- liveness and status ------------------------------------------------

  async liveness() {
    if (this.signals.shellDead) return { alive: false, reason: this.signals.shellDead };
    if (this.primaryPid) {
      try { process.kill(this.primaryPid, 0); return { alive: true, reason: `pid ${this.primaryPid}` }; } catch { return { alive: false, reason: `pid ${this.primaryPid} is gone` }; }
    }
    const fg = await this.foreground().catch(() => null);
    if (fg === null) return { alive: true, reason: 'herdr did not answer; assuming alive' };
    const alive = fg.some((p) => /claude/i.test(p.name || ''));
    return { alive, reason: alive ? 'claude in the foreground' : `foreground is ${fg.map((p) => p.name).join(',') || 'empty'}` };
  }

  // Herdr's own view of the primary: blocked means it stopped to ask the
  // captain a question. Event-driven on the socket transport, a slow poll on
  // the cli transport.
  watchPrimaryStatus() {
    const apply = (status) => {
      const prev = this.signals.status;
      this.signals.status = status;
      if (status === 'blocked' && prev !== 'blocked') {
        this.signals.blocked = 'herdr reports the primary blocked on a question';
      } else if (status !== 'blocked') {
        this.signals.blocked = null;
      }
      // Rare, event-driven dead-primary check: unknown status plus a shell
      // prompt. Not a 1 s pane-read loop.
      if (status === 'unknown' && this.paneId) {
        this.paneText().then((text) => {
          if (atShellPrompt(text)) this.signals.shellDead = 'the pane returned to a shell prompt';
        }).catch(() => {});
      }
    };
    const handle = this.herdr.subscribe([{ type: 'pane.agent_status_changed', pane_id: this.paneId }], (msg) => {
      if (msg.data?.pane_id === this.paneId && msg.data?.agent_status) apply(msg.data.agent_status);
    });
    if (!handle) {
      this.statusPoll = setInterval(async () => {
        try {
          const r = await this.herdr.call('pane.get', { pane_id: this.paneId });
          apply(r.pane?.agent_status ?? 'unknown');
        } catch { /* keep the last known status */ }
      }, 10_000);
    }
  }

  async fetchHerdr(kind, snap, paneIds) {
    if (kind === 'tabs') {
      const r = await this.herdr.call('tab.list');
      snap.herdr.tabLabels = (r.tabs ?? []).map((t) => t.label);
      snap.herdr.tabs = r.tabs ?? [];
    } else if (kind === 'panes') {
      snap.herdr.panes = {};
      for (const id of paneIds) {
        snap.herdr.panes[id] = await this.herdr.call('pane.get', { pane_id: id }).then(() => true).catch(() => false);
      }
    }
  }

  // ---- captain lines ------------------------------------------------------

  async say(text) {
    const t0 = Date.now();
    this.captainLog.push(`${new Date().toISOString()}\t${text}`);
    appendFileSync(join(this.evidenceDir, 'captain.log'), `${this.captainLog.at(-1)}\n`);
    if (this.signals.blocked) {
      // A primary parked on a question takes a menu choice, not text; dismiss
      // the question first, as a captain who wants to say something else would.
      this.snapshot('dismissed-question', await this.paneText().catch(() => ''));
      await this.keys('escape');
      await sleep(800);
      this.signals.blocked = null;
    }
    await this.herdr.call('pane.send_input', { pane_id: this.paneId, text, keys: ['enter'] });
    return Date.now() - t0;
  }

  // /exit the primary and wait for the shell to have it back. Claude raises a
  // "Background work is running" dialog when a shell it started is still
  // alive; its first option, Exit and stop tasks, is what Enter accepts.
  async exitToPrompt(budgetMs = 90_000) {
    const already = await this.paneText().catch(() => '');
    if (atShellPrompt(already)) return true;
    const deadline = Date.now() + budgetMs;
    await this.herdr.call('pane.send_input', { pane_id: this.paneId, text: '/exit', keys: ['enter'] });
    let confirmed = false;
    let lastRead = 0;
    while (Date.now() < deadline) {
      const l = await this.liveness();
      if (!l.alive) return true;
      if (Date.now() - lastRead >= 1500) {
        lastRead = Date.now();
        const text = await this.paneText().catch(() => '');
        if (atShellPrompt(text)) return true;
        if (!confirmed && /Background work is running/.test(text)) {
          this.snapshot('exit-dialog', text);
          await this.keys('enter');
          confirmed = true;
        }
      }
      await sleep(250);
    }
    return false;
  }

  // What a captain does when the window closed and opened again: the primary
  // exits, claude starts again in the same pane, the home and any worker are
  // untouched. Captures the lock identity first so lock.rotated has a baseline.
  async relaunch() {
    const t0 = Date.now();
    this.lockBaseline = this.lockText();
    this.signals.shellDead = null;
    this.snapshot('before-relaunch', await this.paneText().catch(() => ''));
    const exited = await this.exitToPrompt();
    if (!exited) throw new HerdrError('the primary did not exit on /exit within 90 s, so no restart could happen');
    this.signals.blocked = null;
    this.answeredBlocked.clear();
    await this.launch();
    return Date.now() - t0;
  }

  // ---- evidence -----------------------------------------------------------

  keep(name, text) {
    try { writeFileSync(join(this.evidenceDir, name), text); } catch { /* evidence is best effort */ }
  }

  snapshot(label, text) {
    const stamp = new Date().toISOString().slice(11, 19).replace(/:/g, '');
    this.keep(`pane-${stamp}-${label}.txt`, text);
  }

  // Herdr's own classification of the primary's pane (idle, working,
  // blocked...), one pane.get; unknown when herdr does not answer.
  async primaryStatus() {
    try { return (await this.herdr.call('pane.get', { pane_id: this.paneId })).pane?.agent_status ?? 'unknown'; } catch { return 'unknown'; }
  }

  // The primary's pane and every recorded worker's pane, kept when a step
  // fails, so a worker parked on its own dialog is visible in the evidence.
  async snapshotAll(label, snap) {
    try { this.snapshot(label, await this.paneText()); } catch { /* pane may be gone */ }
    for (const id of snap ? recordedPaneIds(snap) : []) {
      try {
        const r = await this.herdr.call('pane.read', { pane_id: id, source: 'visible' });
        this.snapshot(`${label}-worker-${id.replace(/[^A-Za-z0-9_-]/g, '_')}`, r.read?.text ?? '');
      } catch { /* worker pane gone */ }
    }
  }

  noteTaskIds(snap) {
    for (const id of snap.taskIds) {
      this.seenTaskIds.add(id);
      const t = snap.meta[id]?.tasktmp;
      if (t) this.taskTmps.add(t);
    }
  }

  // Task temp directories firstmate recorded for this run's workers, removed
  // only when they live under the OS temp root.
  removeTaskTmps() {
    const root = realpathSafe(tmpdir());
    for (const t of this.taskTmps) {
      if (realpathSafe(t).startsWith(root + sep)) { try { rmSync(t, { recursive: true, force: true }); } catch { /* best effort */ } }
    }
  }

  // ---- close --------------------------------------------------------------

  async close() {
    if (this.closed) return 0;
    this.closed = true;
    const t0 = Date.now();
    if (this.statusPoll) clearInterval(this.statusPoll);
    if (!this.herdr) { this.archive(); this.removeScratch(); return Date.now() - t0; }
    const keep = this.env.FM_CONTROL_KEEP === '1';
    try { this.snapshot('final', await this.paneText()); } catch { /* pane may be gone */ }
    if (!keep) {
      try {
        if ((await this.liveness()).alive) {
          const exited = await this.exitToPrompt(60_000);
          if (!exited) this.log('the primary did not exit on /exit within 60 s; closing its workspace anyway');
        }
      } catch { /* closing the workspace ends it regardless */ }
      this.stopWatcher();
      await this.closeTaskWorkspaces();
      try { await this.herdr.call('workspace.close', { workspace_id: this.workspaceId }); } catch { /* already gone */ }
      await this.destroyPools();
    }
    this.archive();
    if (!keep) { this.removeScratch(); this.removeTaskTmps(); }
    await this.herdr.close({ keepLogAt: join(this.evidenceDir, 'herdr-server.log') });
    return Date.now() - t0;
  }

  stopWatcher() {
    try {
      const pid = Number.parseInt(readFileSync(join(this.home, 'state', '.watch.lock', 'pid'), 'utf8').trim(), 10);
      if (pid > 1) process.kill(pid, 'SIGTERM');
    } catch { /* no watcher, or already gone */ }
  }

  // Only tabs labelled for tasks this home recorded, and only a workspace
  // that did not exist before the run and holds one of them.
  async closeTaskWorkspaces() {
    let tabs = [];
    try { tabs = (await this.herdr.call('tab.list')).tabs ?? []; } catch { return; }
    const want = new Set([...this.seenTaskIds].map((id) => `fm-${id}`));
    for (const t of tabs) {
      if (!want.has(t.label)) continue;
      try { await this.herdr.call('tab.close', { tab_id: t.tab_id }); } catch { /* gone */ }
      if (t.workspace_id !== this.workspaceId && !this.baselineWorkspaces.has(t.workspace_id)) {
        try { await this.herdr.call('workspace.close', { workspace_id: t.workspace_id }); } catch { /* gone */ }
      }
    }
  }

  // Treehouse pools whose worktrees belong to a project inside this home.
  async destroyPools() {
    const root = join(homedir(), '.treehouse');
    let pools = [];
    try { pools = readdirSync(root); } catch { return; }
    const homeReal = safeReal(this.home);
    for (const pool of pools) {
      const poolDir = join(root, pool);
      let mine = false;
      for (const slot of safeList(poolDir).filter((d) => /^\d/.test(d))) {
        for (const wt of safeList(join(poolDir, slot))) {
          const gitFile = join(poolDir, slot, wt, '.git');
          let target = '';
          try {
            const st = lstatSync(gitFile);
            target = st.isDirectory() ? gitFile : (readFileSync(gitFile, 'utf8').match(/gitdir:\s*(.*)/)?.[1] ?? '');
          } catch { continue; }
          if (target && safeReal(target).toLowerCase().startsWith(homeReal.toLowerCase() + sep)) { mine = true; break; }
        }
        if (mine) break;
      }
      if (!mine) continue;
      await new Promise((res) => {
        this.counters.cleanupSpawns += 1;
        const c = spawn('treehouse', ['destroy', poolDir, '--all', '--include-unlanded', '--include-in-use', '--yes'], { stdio: 'ignore', shell: false, windowsHide: true, env: { ...this.env, PATH: this.panePath() } });
        c.on('error', () => res());
        c.on('close', () => res());
      });
      rmSync(poolDir, { recursive: true, force: true });
      this.log(`removed the treehouse pool ${pool} this run created`);
    }
  }

  archive() {
    for (const d of ['state', 'data']) {
      try { cpSync(join(this.home, d), join(this.evidenceDir, 'home', d), { recursive: true, dereference: false, force: true, errorOnExist: false }); } catch { /* absent */ }
    }
    if (this.claudeConfigDir) {
      try { cpSync(this.claudeConfigDir, join(this.evidenceDir, 'claude-config'), { recursive: true }); } catch { /* absent */ }
    }
  }

  removeScratch() {
    try { rmSync(this.scratch, { recursive: true, force: true }); } catch { /* best effort */ }
  }
}

function safeList(p) {
  try { return readdirSync(p); } catch { return []; }
}
function safeReal(p) {
  try { return realpathSync(p); } catch { return p; }
}
const realpathSafe = safeReal;
export function lastLines(text, n = 6) {
  return text.split('\n').filter((l) => /[A-Za-z]/.test(l)).slice(-n).map((l) => l.replace(/\s+/g, ' ').trim()).join(' | ').slice(0, 600);
}
