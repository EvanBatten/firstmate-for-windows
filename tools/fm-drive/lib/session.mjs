// Environment:
//   FM_DRIVE_MODEL        primary model (default opus)
//   FM_DRIVE_READY_MS     implicit-ready budget per launch (default 120000)
//   FM_DRIVE_OPERABLE_MS  wait for lock/digest-complete before the first say (default 240000)
//   FM_DRIVE_UNTIL_MS     default step budget when a step has no budgetSec (default 180000)
//   FM_DRIVE_EVIDENCE     evidence directory (default <tmp>/fm-drive-artifacts/<feature>-<utc>)
//   FM_DRIVE_KEEP         1 keeps the throwaway home and pane after the run
//   FM_DRIVE_TRUST_MS     bound for a visible folder-trust dialog (default 12000)
//   FM_DRIVE_ROOT         checkout to clone as the home (default: the repo holding this file)
//   FM_DRIVE_TOOLS_DIR    tools dir linked into the home as .tools (default: <root>/.tools)
//   FM_DRIVE_PANE_PATH_EXTRA  extra PATH entries for the pane, before the inherited PATH
//   CLAUDE_CODE_OAUTH_TOKEN / CLAUDE_CODE_OATH_TOKEN  passed to the pane as CLAUDE_CODE_OAUTH_TOKEN; never logged

import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, appendFileSync, existsSync, rmSync, cpSync, readdirSync, symlinkSync, realpathSync, lstatSync, statSync, copyFileSync, chmodSync, linkSync, readlinkSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join, dirname, resolve, delimiter, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';
import { Herdr, HerdrError, atShellPrompt, sleep } from './herdr.mjs';
import { recordedPaneIds } from './predicates.mjs';

// Claude Code shows the trust dialog for C:\... but looks the project up as C:/..., so every slash and drive-letter form is written.
export function trustProjectKeys(home) {
  const keys = new Set();
  const add = (p) => { if (p) keys.add(p); };
  add(home);
  add(home.replace(/\\/g, '/'));
  add(home.replace(/\//g, '\\'));
  const m = String(home).match(/^([A-Za-z])([:\\/].*)$/);
  if (m) {
    for (const drive of [m[1].toLowerCase(), m[1].toUpperCase()]) {
      const rest = m[2];
      add(drive + rest);
      add((drive + rest).replace(/\\/g, '/'));
      add((drive + rest).replace(/\//g, '\\'));
    }
  }
  return [...keys];
}

export function isTrustPrompt(text) {
  return /Yes, I trust this folder/.test(String(text || ''));
}

export function prepareClaudeConfig(config, home, env = process.env) {
  mkdirSync(config, { recursive: true });
  const trusted = { hasTrustDialogAccepted: true };
  const projects = {};
  for (const key of trustProjectKeys(home)) projects[key] = { ...trusted };
  writeFileSync(
    join(config, '.claude.json'),
    `${JSON.stringify({
      ...hostAuthState(env),
      hasCompletedOnboarding: true,
      bypassPermissionsModeAccepted: true,
      projects,
    })}\n`,
    { mode: 0o600 },
  );
  const pathValue = [
    join(home, '.tools'),
    join(userHome(env), '.local', 'bin'),
    env.PATH || '',
  ].filter(Boolean).join(delimiter);
  writeFileSync(
    join(config, 'settings.json'),
    `${JSON.stringify({
      theme: 'dark',
      env: {
        PATH: pathValue,
        FM_PANE_PATH: pathValue,
      },
    })}\n`,
    { mode: 0o600 },
  );
  inheritHostCredentials(config, env);
  return config;
}

const DRIVER_CLAUDE_JSON_KEYS = ['hasCompletedOnboarding', 'bypassPermissionsModeAccepted', 'projects'];
const DRIVER_SETTINGS = { theme: null, env: ['PATH', 'FM_PANE_PATH'] };

export function measureClaudeConfig(config) {
  const extra = [];
  for (const name of readdirSync(config).sort()) {
    if (isCredentialFileName(name)) continue;
    if (name === '.claude.json') {
      const json = readJsonQuiet(join(config, name)) ?? {};
      for (const key of Object.keys(json)) {
        if (!isAuthStateKey(key) && !DRIVER_CLAUDE_JSON_KEYS.includes(key)) extra.push(`${name}:${key}`);
      }
    } else if (name === 'settings.json') {
      const json = readJsonQuiet(join(config, name)) ?? {};
      for (const [key, value] of Object.entries(json)) {
        if (!(key in DRIVER_SETTINGS)) extra.push(`${name}:${key}`);
        else if (DRIVER_SETTINGS[key]) {
          for (const sub of Object.keys(value ?? {})) if (!DRIVER_SETTINGS[key].includes(sub)) extra.push(`${name}:${key}.${sub}`);
        }
      }
    } else {
      extra.push(name);
    }
  }
  return extra.length ? `carries ${extra.join(', ')}` : 'clean';
}

function userHome(env) {
  if (process.platform === 'win32') return env.USERPROFILE || env.HOME || homedir();
  return env.HOME || env.USERPROFILE || homedir();
}

export function isAuthStateKey(key) {
  return /oauth|account|apiKey|api_key|userID|userId|authMethod|loggedIn|organizationUuid|refreshToken|accessToken/i.test(key);
}

export function isCredentialFileName(name) {
  return name === '.credentials.json' || name === 'credentials.json';
}

function readJsonQuiet(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; }
}

function hostClaudeJsonPaths(env) {
  const home = userHome(env);
  const paths = [join(home, '.claude.json')];
  if (env.CLAUDE_CONFIG_DIR) paths.push(join(env.CLAUDE_CONFIG_DIR, '.claude.json'));
  paths.push(join(home, '.claude', '.claude.json'));
  return paths;
}

function hostCredentialPaths(env) {
  const home = userHome(env);
  const paths = [];
  if (env.CLAUDE_CONFIG_DIR) paths.push(join(env.CLAUDE_CONFIG_DIR, '.credentials.json'));
  paths.push(join(home, '.claude', '.credentials.json'));
  return paths;
}

function hostAuthState(env) {
  const out = {};
  for (const path of hostClaudeJsonPaths(env)) {
    const parsed = readJsonQuiet(path);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) continue;
    for (const [key, value] of Object.entries(parsed)) {
      if (isAuthStateKey(key)) out[key] = value;
    }
  }
  return out;
}

// CLAUDE_CONFIG_DIR redirects Claude's auth too, so the host login is inherited; a hardlink keeps a mid-run
// token refresh on the host's own file.
function inheritHostCredentials(config, env) {
  const dest = join(config, '.credentials.json');
  for (const src of hostCredentialPaths(env)) {
    if (!existsSync(src) || src === dest) continue;
    try {
      try { linkSync(src, dest); } catch {
        copyFileSync(src, dest);
        try { chmodSync(dest, 0o600); } catch {}
      }
    } catch {
      // absence or an unreadable host file leaves the pane on env-token auth
    }
    return;
  }
}

export function archiveClaudeConfig(src, dest) {
  mkdirSync(dest, { recursive: true });
  for (const name of readdirSync(src)) {
    if (isCredentialFileName(name)) continue;
    const from = join(src, name);
    const to = join(dest, name);
    let st;
    try { st = lstatSync(from); } catch { continue; }
    if (st.isDirectory()) {
      archiveClaudeConfig(from, to);
      continue;
    }
    if (name === '.claude.json' || name === 'claude.json') {
      const parsed = readJsonQuiet(from);
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        const redacted = {};
        for (const [key, value] of Object.entries(parsed)) {
          if (!isAuthStateKey(key)) redacted[key] = value;
        }
        writeFileSync(to, `${JSON.stringify(redacted)}\n`);
        continue;
      }
    }
    copyFileSync(from, to);
  }
}

const HERE = dirname(fileURLToPath(import.meta.url));
const PROCESS_POLL_EVERY_N_TICKS = 3;
export const DEFAULT_ROOT = resolve(HERE, '..', '..', '..');
export const driveRoot = (env) => env.FM_DRIVE_ROOT || DEFAULT_ROOT;

export class Session {
  constructor({ trace, env = process.env, log = () => {} }) {
    this.trace = trace;
    this.env = env;
    this.log = log;
    this.model = env.FM_DRIVE_MODEL || 'opus';
    this.readyMs = Number.parseInt(env.FM_DRIVE_READY_MS || '120000', 10);
    this.operableBudgetMs = Number.parseInt(env.FM_DRIVE_OPERABLE_MS || '240000', 10);
    this.trustBoundMs = Number.parseInt(env.FM_DRIVE_TRUST_MS || '12000', 10);
    this.trustSeenAt = null;
    this.dialogBusy = false;
    this.dialogPoll = null;
    if (!this.env.CLAUDE_CODE_OAUTH_TOKEN && this.env.CLAUDE_CODE_OATH_TOKEN) {
      this.env = { ...this.env, CLAUDE_CODE_OAUTH_TOKEN: this.env.CLAUDE_CODE_OATH_TOKEN };
    }
    this.root = driveRoot(env);
    this.scratch = null;
    this.home = null;
    this.herdr = null;
    this.workspaceId = null;
    this.paneId = null;
    this.shell = 'bash';
    this.primaryPid = null;
    this.launches = 0;
    this.readyLaunch = null;
    this.lockBaseline = undefined;
    this.seeds = {};
    this.projectOrigin = null;
    this.seenTaskIds = new Set();
    this.taskTmps = new Set();
    this.baselineWorkspaces = new Set();
    this.signals = { blocked: null, status: null, shellDead: null };
    this.claudeConfigDir = null;
    this.code = null;
    this.statusPoll = null;
    this.counters = { gitSpawns: 0, setupSpawns: 0, cleanupSpawns: 0 };
    this.captainLog = [];
    this.closed = false;
    const stamp = new Date().toISOString().replace(/[:.]/g, '').slice(0, 15);
    this.evidenceDir = env.FM_DRIVE_EVIDENCE || join(tmpdir(), 'fm-drive-artifacts', `${trace.feature}-${stamp}`);
  }

  async cloneFresh() {
    this.scratch = mkdtempSync(join(tmpdir(), `fm-drive-${this.trace.feature}-`));
    this.home = join(this.scratch, 'firstmate');
    await this.cloneHome();
  }

  async prepare() {
    this.evidenceCreated = mkdirSync(this.evidenceDir, { recursive: true }) !== undefined;
    await this.cloneFresh();
    if (this.trace.steps.some((s) => s.say.includes('{{projectOrigin}}'))) {
      await this.seedProject(this.trace.project || 'greeter');
    }
    this.claudeConfigDir = prepareClaudeConfig(join(this.scratch, 'claude-config'), this.home, this.env);
  }

  async open() {
    this.herdr = await Herdr.attach(this.env, { log: this.log });
    try {
      const list = await this.herdr.call('workspace.list');
      for (const w of list.workspaces ?? []) this.baselineWorkspaces.add(w.workspace_id);
    } catch {
      // a baseline is a courtesy for cleanup; its absence closes nothing extra
    }
    // TMUX is blanked so a herdr server that happens to run under tmux still
    // yields a pane where firstmate auto-detects herdr, not tmux.
    // herdr drops PATH from pane env, so it rides in as FM_PANE_PATH (platform/windows/pane-rc.sh).
    const paneEnv = { FM_PANE_PATH: this.panePath(), PATH: this.panePath(), TMUX: '', TMUX_PANE: '', CLAUDE_CONFIG_DIR: this.claudeConfigDir };
    const token = this.env.CLAUDE_CODE_OAUTH_TOKEN || this.env.CLAUDE_CODE_OATH_TOKEN || '';
    if (token) paneEnv.CLAUDE_CODE_OAUTH_TOKEN = token;
    const created = await this.herdr.call('workspace.create', { cwd: this.home, label: `fm-drive-${this.trace.feature}`, focus: false, env: paneEnv });
    this.workspaceId = created.workspace?.workspace_id;
    this.paneId = created.root_pane?.pane_id;
    if (!this.workspaceId || !this.paneId) throw new HerdrError('herdr created a workspace but reported no pane for it');
    this.keep('workspace.json', JSON.stringify({ workspace_id: this.workspaceId, pane_id: this.paneId, session: this.herdr.session, transport: this.herdr.transport }, null, 2));
    const info = await this.herdr.call('pane.process_info', { pane_id: this.paneId });
    const shellName = (info.process_info?.foreground_processes?.[0]?.name || '').toLowerCase();
    if (/pwsh|powershell/.test(shellName)) this.shell = 'pwsh';
    else if (shellName === 'cmd' || shellName === 'cmd.exe') this.shell = 'cmd';
    else this.shell = 'posix';
    const paneRc = join(this.home, 'platform', 'windows', 'pane-rc.sh');
    if (this.shell === 'pwsh' && existsSync(paneRc)) await this.enterGitBash(paneRc);
    this.watchPrimaryStatus();
  }

  // The primary runs where the Windows overlay runs every herdr pane: an
  // interactive Git Bash on pane-rc.sh, which loads env.sh. Text typed before
  // that bash sets its title loses its head, so the launch waits for it.
  async enterGitBash(paneRc) {
    const gitExec = await this.git(['--exec-path']);
    const bash = resolve(gitExec, '..', '..', '..', 'usr', 'bin', 'bash.exe');
    if (!existsSync(bash)) throw new HerdrError(`no Git Bash at ${bash}, derived from git --exec-path ${gitExec}`);
    const quote = (s) => `'${s.replace(/'/g, "''")}'`;
    const rc = paneRc.replace(/\\/g, '/');
    await this.herdr.call('pane.send_input', { pane_id: this.paneId, text: `& ${quote(bash)} --rcfile ${quote(rc)} -i; exit`, keys: ['enter'] });
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      const title = ((await this.herdr.call('pane.get', { pane_id: this.paneId })).pane?.terminal_title ?? '').toLowerCase();
      if (title && !title.endsWith('.exe')) {
        this.shell = 'git-bash';
        return;
      }
      await sleep(100);
    }
    this.snapshot('git-bash-not-ready', await this.paneText().catch(() => ''));
    throw new HerdrError('the primary pane did not start Git Bash on pane-rc.sh within 30 s');
  }

  panePath() {
    const parts = [
      join(this.home, '.tools'),
      join(this.home, '.tools', 'node_modules', '.bin'),
      join(userHome(this.env), '.local', 'bin'),
    ];
    if (this.env.FM_DRIVE_PANE_PATH_EXTRA) parts.push(this.env.FM_DRIVE_PANE_PATH_EXTRA);
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

  async gitBytes(args) {
    this.counters.setupSpawns += 1;
    return new Promise((resolvePromise, reject) => {
      const child = spawn('git', args, { stdio: ['ignore', 'pipe', 'ignore'], shell: false, windowsHide: true });
      const chunks = [];
      child.stdout.on('data', (d) => chunks.push(d));
      child.on('error', reject);
      child.on('close', (code) => (code === 0 ? resolvePromise(Buffer.concat(chunks)) : reject(new Error(`git ${args.slice(2, 4).join(' ')} exited ${code}`))));
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
        const patch = await this.gitBytes(['-C', this.root, 'diff', 'HEAD', '--binary']);
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
    const tools = this.env.FM_DRIVE_TOOLS_DIR || join(this.root, '.tools');
    if (existsSync(tools)) {
      try { symlinkSync(realpathSync(tools), join(this.home, '.tools'), 'dir'); } catch { cpSync(tools, join(this.home, '.tools'), { recursive: true }); }
    }
    const skills = join(this.home, '.claude', 'skills');
    try {
      if (!lstatSync(skills).isSymbolicLink() || !existsSync(skills)) throw new Error('unresolved');
    } catch {
      throw new HerdrError("the clone's harness skill link does not resolve, so the primary would have no skills");
    }
    this.code = { sha, dirty: dirty !== '' };
    this.keep('code.txt', `root ${this.root}\nbranch ${branch}\ncommit ${sha}\nhome ${this.home}\n${dirty ? `uncommitted:\n${dirty}\n` : ''}`);
  }

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

  launchLine() {
    const flags = `--dangerously-skip-permissions --model ${this.model}`;
    const home = this.home;
    const cfg = this.claudeConfigDir;
    if (this.shell === 'pwsh') {
      return `if ($env:FM_PANE_PATH) { $env:Path = $env:FM_PANE_PATH }; $env:CLAUDE_CONFIG_DIR = '${cfg.replace(/'/g, "''")}'; Set-Location '${home.replace(/'/g, "''")}'; claude ${flags}`;
    }
    if (this.shell === 'cmd') {
      return `set "PATH=%FM_PANE_PATH%" && set "CLAUDE_CONFIG_DIR=${cfg}" && cd /d "${home}" && claude ${flags}`;
    }
    if (this.shell === 'git-bash') {
      return `export CLAUDE_CONFIG_DIR='${cfg.replace(/'/g, "'\\''")}'; cd "$(cygpath -u '${home.replace(/'/g, "'\\''")}')" && claude ${flags}`;
    }
    return `export PATH="$FM_PANE_PATH"; export CLAUDE_CONFIG_DIR='${cfg.replace(/'/g, "'\\''")}'; cd '${home.replace(/'/g, "'\\''")}' && claude ${flags}`;
  }

  async fidelity() {
    if (this.committedHooks === undefined) {
      this.committedHooks = await this.gitBytes(['-C', this.home, 'show', 'HEAD:.claude/settings.json']).catch(() => null);
    }
    let settings = null;
    try { settings = readFileSync(join(this.home, '.claude', 'settings.json')); } catch {}
    const same = this.committedHooks === null ? settings === null : settings !== null && this.committedHooks.equals(settings);
    let captainMd = 'untouched';
    try {
      const { mtimeMs } = statSync(join(this.home, 'data', 'captain.md'));
      captainMd = this.firstSaidAt !== undefined && mtimeMs >= this.firstSaidAt ? 'written-after-say' : 'present';
    } catch {}
    return {
      claudeConfig: measureClaudeConfig(this.claudeConfigDir),
      hooks: same ? 'repo' : 'modified',
      captainMd,
      model: this.model,
    };
  }

  async launch() {
    const t0 = Date.now();
    this.primaryPid = null;
    this.launches += 1;
    this.readyLaunch = null;
    this.signals.shellDead = null;
    await this.herdr.call('pane.send_input', { pane_id: this.paneId, text: this.launchLine(), keys: ['enter'] });
    await this.awaitReady();
    this.readyLaunch = this.launches;
    this.watchDialogs();
    return Date.now() - t0;
  }

  async foreground() {
    const info = await this.herdr.call('pane.process_info', { pane_id: this.paneId });
    return info.process_info?.foreground_processes ?? [];
  }

  lockText() {
    return readHomeStateFile(this.home, '.lock');
  }

  sessionStartCompleteText() {
    return readHomeStateFile(this.home, '.session-start-complete');
  }

  homeOperable() {
    return homeIsOperable(this.home);
  }

  async paneText(source = 'visible', lines) {
    const r = await this.herdr.call('pane.read', { pane_id: this.paneId, source, ...(lines ? { lines } : {}) });
    return r.read?.text ?? '';
  }

  async keys(...keys) {
    await this.herdr.call('pane.send_input', { pane_id: this.paneId, keys });
  }

  // Claude's folder-trust dialog defaults to "No, exit"; Enter only after the cursor is on Yes.
  async answerDialog(text) {
    const cursorOnNo = /❯\s*No/.test(text);
    if (isTrustPrompt(text)) {
      this.snapshot('trust-prompt', text);
      this.trustSeenAt ??= Date.now();
      if (Date.now() - this.trustSeenAt > this.trustBoundMs) {
        this.snapshot('trust-prompt-stuck', text);
        throw new HerdrError('the primary stayed on the folder trust dialog');
      }
      if (/❯\s*Yes/.test(text)) {
        await this.keys('enter');
        return true;
      }
      await this.keys('down');
      return true;
    }
    this.trustSeenAt = null;
    if (/Yes, I accept/.test(text) && /[Bb]ypass [Pp]ermissions/.test(text)) {
      this.snapshot('bypass-prompt', text);
      if (cursorOnNo) { await this.keys('down'); await sleep(250); }
      await this.keys('enter');
      return true;
    }
    if (/Select login method/.test(text)) {
      this.snapshot('login-prompt', text);
      throw new HerdrError('claude opened its first-run login dialog in the pane; the throwaway CLAUDE_CONFIG_DIR did not skip onboarding (host claude.ai login was not inherited, and CLAUDE_CODE_OAUTH_TOKEN is missing)');
    }
    if (/Light mode \(ANSI colors only\)/.test(text)) {
      this.snapshot('theme-prompt', text);
      await this.keys('enter');
      return true;
    }
    return false;
  }

  // After ready, folder trust can still appear (ready can fire on the
  // splash). Poll so waitUntil does not spend a step budget on "No, exit".
  // A stuck prompt sets signals.blocked and fails the step.
  watchDialogs() {
    if (this.dialogPoll) return;
    this.dialogPoll = setInterval(async () => {
      if (this.closed || this.dialogBusy) return;
      this.dialogBusy = true;
      try {
        const text = await this.paneText().catch(() => '');
        if (!text) return;
        try {
          await this.answerDialog(text);
        } catch (err) {
          this.signals.blocked = err.message;
        }
      } finally {
        this.dialogBusy = false;
      }
    }, 2000);
    this.dialogPoll.unref?.();
  }

  // Ready can fire on the splash before session start takes the helm; sayWhenOperable waits for that.
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
      // On the cli transport each process-list ask is a process, so it is asked only when it can decide something.
      if (lockFresh || prompted || tick % PROCESS_POLL_EVERY_N_TICKS === 0) {
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
        } else if (sawClaude) {
          // Only a claude that reached the foreground and left it has exited;
          // one still starting behind its echoed launch line has not.
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

  // The first say waits for an operable home so a step budget does not start during splash.
  // If the splash is idle and session-start is not in the pane, the hook
  // stood down and the first say is what starts session-start; send it and
  // keep waiting for the lock. If the pane already shows fm-session-start
  // (including a persistent-cd denial), leave it alone and wait.
  async sayWhenOperable(text, withholdReason = async () => null) {
    const t0 = Date.now();
    const deadline = t0 + this.operableBudgetMs;
    let sayMs = 0;
    let said = false;
    let withheld = null;
    const send = async () => {
      if (said || text === '') return;
      said = true;
      withheld = await withholdReason();
      if (!withheld) sayMs = await this.say(text);
    };
    const done = () => ({ sayMs, withheld, operableMs: Math.max(0, Date.now() - t0 - sayMs) });

    while (Date.now() < deadline) {
      const pane = await this.paneText().catch(() => '');
      if (await this.answerDialog(pane)) { await sleep(400); continue; }
      if (this.homeOperable()) {
        if (!said) await send();
        return done();
      }
      if (atShellPrompt(pane) && (this.primaryPid || /claude --dangerously/.test(pane))) {
        this.snapshot('exited-before-operable', pane);
        throw new HerdrError(`the primary exited before the home was operable. Its pane shows: ${lastLines(pane)}`);
      }
      if (isSessionStartBusy(pane)) {
        await sleep(1000);
        continue;
      }
      await send();
      if (withheld) return done();
      await sleep(1000);
    }
    if (this.homeOperable()) {
      if (!said) await send();
      return done();
    }
    const pane = await this.paneText().catch(() => '');
    this.snapshot('not-operable', pane);
    throw new HerdrError(`the home did not become operable within ${Math.round(this.operableBudgetMs / 1000)} s. Its pane shows: ${lastLines(pane)}`);
  }

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

  watchPrimaryStatus() {
    const apply = (status) => {
      this.signals.status = status;
      if (status === 'blocked') {
        // A persistent-cd denial of `cd ... && fm-session-start` is not a
        // parked captain question; the primary retries without cd.
        this.paneText().then((text) => {
          this.signals.blocked = isSessionStartBusy(text)
            ? null
            : 'herdr reports the primary blocked on a question';
        }).catch(() => {
          this.signals.blocked = 'herdr reports the primary blocked on a question';
        });
      } else {
        this.signals.blocked = null;
      }
      // Rare, event-driven dead-primary check: unknown status plus a shell
      // prompt. Not a 1 s pane-read loop. Until the latest launch is ready the
      // pane still shows the shell that launches claude, so a read taken
      // then proves nothing.
      if (status === 'unknown' && this.paneId) {
        const launch = this.readyLaunch;
        this.paneText().then((text) => {
          if (launch !== null && launch === this.readyLaunch && atShellPrompt(text)) this.signals.shellDead = 'the pane returned to a shell prompt';
        }).catch(() => {});
      }
    };
    const handle = this.herdr.subscribe([{ type: 'pane.agent_status_changed', pane_id: this.paneId }], (msg) => {
      if (msg.data?.pane_id === this.paneId && msg.data?.agent_status) apply(msg.data.agent_status);
    });
    if (!handle) {
      const poll = async () => {
        try {
          const r = await this.herdr.call('pane.get', { pane_id: this.paneId });
          apply(r.pane?.agent_status ?? 'unknown');
        } catch { /* keep the last known status */ }
      };
      poll();
      this.statusPoll = setInterval(poll, 10_000);
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

  async say(text) {
    const t0 = Date.now();
    this.firstSaidAt ??= t0;
    this.captainLog.push(`${new Date().toISOString()}\t${text}`);
    appendFileSync(join(this.evidenceDir, 'captain.log'), `${this.captainLog.at(-1)}\n`);
    if (this.signals.blocked) {
      const pane = await this.paneText().catch(() => '');
      if (isSessionStartBusy(pane)) {
        this.signals.blocked = null;
      } else {
        // A primary parked on a question takes a menu choice, not text; dismiss
        // the question first, as a captain who wants to say something else would.
        this.snapshot('dismissed-question', pane);
        await this.keys('escape');
        await sleep(800);
        this.signals.blocked = null;
      }
    }
    await this.herdr.call('pane.send_input', { pane_id: this.paneId, text, keys: ['enter'] });
    return Date.now() - t0;
  }

  // Claude's "Background work is running" exit dialog: Enter accepts its first option, Exit and stop tasks.
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

  // The lock identity is captured before /exit so lock.rotated has a baseline.
  async relaunch() {
    const t0 = Date.now();
    this.lockBaseline = this.lockText();
    this.signals.shellDead = null;
    this.trustSeenAt = null;
    this.snapshot('before-relaunch', await this.paneText().catch(() => ''));
    const exited = await this.exitToPrompt();
    if (!exited) throw new HerdrError('the primary did not exit on /exit within 90 s, so no restart could happen');
    this.signals.blocked = null;
    await this.launch();
    return Date.now() - t0;
  }

  keep(name, text) {
    try { writeFileSync(join(this.evidenceDir, name), text); } catch {}
  }

  snapshot(label, text) {
    const stamp = new Date().toISOString().slice(11, 19).replace(/:/g, '');
    this.keep(`pane-${stamp}-${label}.txt`, text);
  }

  async primaryStatus() {
    try { return (await this.herdr.call('pane.get', { pane_id: this.paneId })).pane?.agent_status ?? 'unknown'; } catch { return 'unknown'; }
  }

  async snapshotAll(label, snap) {
    try { this.snapshot(label, await this.paneText()); } catch {}
    for (const id of snap ? recordedPaneIds(snap) : []) {
      try {
        const r = await this.herdr.call('pane.read', { pane_id: id, source: 'visible' });
        this.snapshot(`${label}-worker-${id.replace(/[^A-Za-z0-9_-]/g, '_')}`, r.read?.text ?? '');
      } catch {}
    }
  }

  noteTaskIds(snap) {
    for (const id of snap.taskIds) {
      this.seenTaskIds.add(id);
      const t = snap.meta[id]?.tasktmp;
      if (t) this.taskTmps.add(t);
    }
  }

  removeTaskTmps() {
    const root = realpathSafe(tmpdir());
    for (const t of this.taskTmps) {
      if (realpathSafe(t).startsWith(root + sep)) { try { rmSync(t, { recursive: true, force: true }); } catch {} }
    }
  }

  async close({ keepEvidence = true } = {}) {
    if (this.closed) return 0;
    this.closed = true;
    const t0 = Date.now();
    if (this.statusPoll) clearInterval(this.statusPoll);
    if (this.dialogPoll) clearInterval(this.dialogPoll);
    if (!this.herdr) {
      if (keepEvidence) this.archive();
      else if (this.evidenceCreated) rmSync(this.evidenceDir, { recursive: true, force: true });
      this.removeScratch();
      return Date.now() - t0;
    }
    const keep = this.env.FM_DRIVE_KEEP === '1';
    try { this.snapshot('final', await this.paneText()); } catch {}
    if (!keep) {
      try {
        if ((await this.liveness()).alive) {
          const exited = await this.exitToPrompt(60_000);
          if (!exited) this.log('the primary did not exit on /exit within 60 s; closing its workspace anyway');
        }
      } catch { /* closing the workspace ends it regardless */ }
      await this.stopWatcher();
      await this.closeTaskWorkspaces();
      try { await this.herdr.call('workspace.close', { workspace_id: this.workspaceId }); } catch {}
      await this.destroyPools();
    }
    this.archive();
    if (!keep) { this.removeScratch(); this.removeTaskTmps(); }
    await this.herdr.close({ keepLogAt: join(this.evidenceDir, 'herdr-server.log') });
    return Date.now() - t0;
  }

  async stopWatcher() {
    let pid;
    try { pid = Number.parseInt(readFileSync(join(this.home, 'state', '.watch.lock', 'pid'), 'utf8').trim(), 10); } catch { return; }
    if (!(pid > 1)) return;
    const outcome = await stopPid(pid, this.env);
    this.keep('watcher.txt', `pid ${pid} ${outcome}\n`);
    this.log(`the home's watcher, pid ${pid}, ${outcome}`);
  }

  async closeTaskWorkspaces() {
    let tabs = [];
    try { tabs = (await this.herdr.call('tab.list')).tabs ?? []; } catch { return; }
    const want = new Set([...this.seenTaskIds].map((id) => `fm-${id}`));
    for (const t of tabs) {
      if (!want.has(t.label)) continue;
      try { await this.herdr.call('tab.close', { tab_id: t.tab_id }); } catch {}
      if (t.workspace_id !== this.workspaceId && !this.baselineWorkspaces.has(t.workspace_id)) {
        try { await this.herdr.call('workspace.close', { workspace_id: t.workspace_id }); } catch {}
      }
    }
  }

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
      copyTreeBestEffort(join(this.home, d), join(this.evidenceDir, 'home', d));
    }
    if (this.claudeConfigDir) {
      try { archiveClaudeConfig(this.claudeConfigDir, join(this.evidenceDir, 'claude-config')); } catch {}
    }
  }

  removeScratch() {
    try { rmSync(this.scratch, { recursive: true, force: true }); } catch {}
  }
}

function safeList(p) {
  try { return readdirSync(p); } catch { return []; }
}
function safeReal(p) {
  try { return realpathSync(p); } catch { return p; }
}
const realpathSafe = safeReal;

function readHomeStateFile(home, name) {
  try { return readFileSync(join(home, 'state', name), 'utf8').trim() || null; } catch { return null; }
}

// cpSync kills the process on Windows (node 24) when an entry vanishes mid-copy,
// which the watcher's lock-owner directories do; try/catch cannot stop that.
export function copyTreeBestEffort(src, dst, { beforeEntry = () => {} } = {}) {
  const walk = (rel) => {
    let names;
    try { names = readdirSync(join(src, rel)); mkdirSync(join(dst, rel), { recursive: true }); } catch { return; }
    for (const name of names) {
      const child = rel ? `${rel}/${name}` : name;
      beforeEntry(child);
      try {
        const st = lstatSync(join(src, child));
        if (st.isDirectory()) walk(child);
        else if (st.isSymbolicLink()) symlinkSync(readlinkSync(join(src, child)), join(dst, child));
        else if (st.isFile()) copyFileSync(join(src, child), join(dst, child));
      } catch {}
    }
  };
  walk('');
}

// fm-watch.sh records its MSYS pid on Windows, which process.kill cannot reach;
// Git for Windows' own kill.exe can.
function signaller(pid, env) {
  if (process.platform !== 'win32') {
    return (sig) => { try { process.kill(pid, sig === '0' ? 0 : `SIG${sig}`); return true; } catch { return false; } };
  }
  const kill = msysKill(env);
  return kill && ((sig) => spawnSync(kill, [`-${sig}`, String(pid)], { stdio: 'ignore', windowsHide: true }).status === 0);
}

function msysKill(env) {
  for (const dir of (env.PATH ?? env.Path ?? '').split(delimiter)) {
    if (!dir || !existsSync(join(dir, 'git.exe'))) continue;
    for (const up of [['..'], ['..', '..']]) {
      const kill = join(dir, ...up, 'usr', 'bin', 'kill.exe');
      if (existsSync(kill)) return kill;
    }
  }
  return null;
}

export async function stopPid(pid, env) {
  const send = signaller(pid, env);
  if (!send) return 'not stopped: no kill.exe beside git on PATH';
  send('TERM');
  for (let i = 0; i < 25; i++) {
    if (!send('0')) return 'stopped';
    await sleep(200);
  }
  return 'still running 5 s after TERM';
}

export function homeIsOperable(home) {
  return readHomeStateFile(home, '.lock') !== null || readHomeStateFile(home, '.session-start-complete') !== null;
}

// Pane is busy with session-start, including a persistent-cd hook denial of
// `cd ... && fm-session-start`. Not a parked captain question.
export function isSessionStartBusy(text) {
  return /fm-session-start/.test(String(text || ''));
}

export function lastLines(text, n = 6) {
  return text.split('\n').filter((l) => /[A-Za-z]/.test(l)).slice(-n).map((l) => l.replace(/\s+/g, ' ').trim()).join(' | ').slice(0, 600);
}
