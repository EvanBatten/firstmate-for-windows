import { readFileSync, writeFileSync, mkdirSync, rmSync, appendFileSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const TRUST_NO = [
  'Accessing workspace:',
  '',
  ' ❯ No, exit',
  '   Yes, I trust this folder',
  '',
  'Enter to confirm',
].join('\n');
const TRUST_YES = [
  'Accessing workspace:',
  '',
  '   No, exit',
  ' ❯ Yes, I trust this folder',
  '',
  'Enter to confirm',
].join('\n');

const DIR = process.env.FAKE_HERDR_DIR;
if (!DIR) { process.stderr.write('FAKE_HERDR_DIR is required\n'); process.exit(64); }
mkdirSync(DIR, { recursive: true });
const STATE = join(DIR, 'state.json');
const args = process.argv.slice(2);

function load() {
  try { return JSON.parse(readFileSync(STATE, 'utf8')); } catch { return { home: null, lockSeq: 0, primary: null, sends: [], launches: 0, exits: 0 }; }
}
function save(s) { writeFileSync(STATE, JSON.stringify(s, null, 2)); }
function out(obj) { process.stdout.write(`${JSON.stringify(obj)}\n`); }
function fail(msg, code = 1) { out({ error: { message: msg } }); process.exit(code); }

function stripSession(a) {
  const r = [];
  for (let i = 0; i < a.length; i++) {
    if (a[i] === '--session') { i += 1; continue; }
    r.push(a[i]);
  }
  return r;
}

function primaryAlive(s) {
  if (!s.primary) return false;
  try { process.kill(s.primary.pid, 0); return true; } catch { return false; }
}

function writeLock(s) {
  mkdirSync(join(s.home, 'state'), { recursive: true });
  const id = `fake-${s.lockSeq}\n`;
  writeFileSync(join(s.home, 'state', '.lock'), id);
  writeFileSync(join(s.home, 'state', '.session-start-complete'), id);
  s.lockAt = Date.now();
}

function startPrimary(s, launchLine) {
  const child = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 600000)'], { detached: true, stdio: 'ignore', windowsHide: true });
  child.unref();
  s.primary = { pid: child.pid };
  if (process.env.FAKE_HERDR_TRUST === '1') s.trust = 'no';
  s.launches += 1;
  s.lockSeq += 1;
  s.launchLine = launchLine;
  s.startingCalls = Number.parseInt(process.env.FAKE_HERDR_CLAUDE_START_CALLS || '0', 10);
  if (s.startingCalls > 0) return;
  const delay = Number.parseInt(process.env.FAKE_HERDR_LOCK_DELAY_MS || '0', 10);
  if (delay > 0) {
    const child = spawn(process.execPath, [fileURLToPath(import.meta.url), '--lock-later', JSON.stringify({ home: s.home, lockSeq: s.lockSeq, delay })], { detached: true, stdio: 'ignore', env: process.env, windowsHide: true });
    child.unref();
  } else writeLock(s);
}

function killPrimary(s) {
  if (s.primary) { try { process.kill(s.primary.pid); } catch {} }
  s.primary = null;
}

const git = (cwd, ...a) => spawnSync('git', ['-C', cwd, ...a], { stdio: 'ignore' });

async function applyWrites(home, writes, sayText) {
  for (const w of writes) {
    if (w.delayMs !== undefined) {
      await new Promise((r) => setTimeout(r, w.delayMs));
    } else if (w.path !== undefined) {
      const p = join(home, w.path);
      mkdirSync(dirname(p), { recursive: true });
      writeFileSync(p, w.content ?? '');
    } else if (w.mkdir !== undefined) {
      mkdirSync(join(home, w.mkdir), { recursive: true });
    } else if (w.remove !== undefined) {
      rmSync(join(home, w.remove), { recursive: true, force: true });
    } else if (w.cloneFromSay !== undefined) {
      const origin = /from (\S+) as/.exec(sayText ?? '')?.[1];
      if (origin) {
        mkdirSync(dirname(join(home, w.cloneFromSay)), { recursive: true });
        spawnSync('git', ['clone', '-q', origin, join(home, w.cloneFromSay)], { stdio: 'ignore' });
      }
    } else if (w.commitIn !== undefined) {
      const repo = join(home, w.commitIn);
      writeFileSync(join(repo, w.file), w.content ?? '');
      git(repo, 'add', '-A');
      git(repo, '-c', 'user.email=fake@example.invalid', '-c', 'user.name=fake', 'commit', '-qm', `add ${w.file}`);
    } else if (w.pushRemote !== undefined) {
      const work = join(DIR, `push-${Date.now()}`);
      spawnSync('git', ['clone', '-q', process.env.FM_DRIVE_REMOTE_ORIGIN, work], { stdio: 'ignore' });
      writeFileSync(join(work, w.pushRemote), w.content ?? '');
      git(work, 'add', '-A');
      git(work, '-c', 'user.email=fake@example.invalid', '-c', 'user.name=fake', 'commit', '-qm', `update ${w.pushRemote}`);
      git(work, 'push', '-q', 'origin', 'HEAD:main');
      rmSync(work, { recursive: true, force: true });
    } else if (w.status !== undefined) {
      const s = load();
      s.status = w.status;
      s.statuses = [...(s.statuses ?? []), { status: w.status, t: Date.now() }];
      save(s);
    } else if (w.killPrimary) {
      const s = load();
      killPrimary(s);
      save(s);
    }
  }
}

// Internal: apply the scripted actions in a detached child so the CLI call
// itself returns immediately, like a herdr that has typed the line.
if (args[0] === '--apply') {
  const { home, writes, sayText } = JSON.parse(args[1]);
  await applyWrites(home, writes, sayText);
} else if (args[0] === '--lock-later') {
  const { home, lockSeq, delay } = JSON.parse(args[1]);
  await new Promise((r) => setTimeout(r, delay));
  const s = load();
  s.home = s.home || home;
  s.lockSeq = lockSeq;
  writeLock(s);
  save(s);
} else {
  appendFileSync(join(DIR, 'calls.log'), `${JSON.stringify(args)}\n`);
  const a = stripSession(args);
  const s = load();
  const verb = `${a[0]} ${a[1] ?? ''}`.trim();
  switch (verb) {
    case 'status --json': {
      const running = process.env.FAKE_HERDR_SERVER_DOWN !== '1' || s.serverUp === true;
      out({ client: { version: 'fake', protocol: 16, session: null }, server: { running, socket: '', protocol: 16, version: 'fake' } });
      break;
    }
    case 'server': {
      writeFileSync(join(DIR, 'server-env.json'), JSON.stringify(process.env));
      s.serverUp = true;
      save(s);
      setInterval(() => { if (!load().serverUp) process.exit(0); }, 100);
      break;
    }
    case 'workspace list':
      out({ workspaces: [] });
      break;
    case 'workspace create': {
      const i = a.indexOf('--cwd');
      s.home = a[i + 1];
      const envPairs = a.filter((x, k) => a[k - 1] === '--env');
      s.env = envPairs.map((kv) => kv.split('=')[0]);
      const config = envPairs.find((kv) => kv.startsWith('CLAUDE_CONFIG_DIR='));
      if (config) s.claudeConfigDir = config.slice('CLAUDE_CONFIG_DIR='.length);
      save(s);
      out({ workspace: { workspace_id: 'ws-fake' }, root_pane: { pane_id: 'pane-fake' } });
      break;
    }
    case 'workspace close':
    case 'tab close':
    case 'server stop':
      if (verb === 'workspace close') { killPrimary(s); save(s); }
      if (verb === 'server stop') { s.serverUp = false; save(s); }
      out({});
      break;
    case 'pane process-info': {
      if (s.startingCalls > 0) {
        s.startingCalls -= 1;
        if (s.startingCalls === 0) writeLock(s);
        save(s);
        out({ process_info: { shell_pid: process.ppid, foreground_processes: [{ pid: process.ppid, name: 'pwsh', argv: ['pwsh'] }] } });
        break;
      }
      const alive = primaryAlive(s);
      out({ process_info: { shell_pid: process.ppid, foreground_processes: alive ? [{ pid: s.primary.pid, name: 'claude', argv: ['claude'] }] : [{ pid: process.ppid, name: 'bash', argv: ['bash'] }] } });
      break;
    }
    case 'pane get':
      out({ pane: { pane_id: a[2], agent_status: s.status ?? (process.env.FAKE_HERDR_STATUS || 'idle') } });
      break;
    case 'pane read':
      if (!primaryAlive(s)) process.stdout.write('\n$ \n');
      else if (s.startingCalls > 0) process.stdout.write(`\nfirstmate on main\n❯ ${s.launchLine}\n`);
      else if (process.env.FAKE_HERDR_TRUST === '1' && s.trust && s.trust !== 'done') {
        process.stdout.write(s.trust === 'yes' ? TRUST_YES : TRUST_NO);
      } else if (process.env.FAKE_HERDR_PANE_UNTIL_LOCK && !existsSync(join(s.home, 'state', '.lock'))) process.stdout.write(process.env.FAKE_HERDR_PANE_UNTIL_LOCK);
      else if (process.env.FAKE_HERDR_PANE) process.stdout.write(process.env.FAKE_HERDR_PANE);
      else process.stdout.write('\n> \n\nbypass permissions on\n');
      break;
    case 'pane send-keys': {
      const keys = a.slice(3);
      s.sends.push({ keys, t: Date.now() });
      if (process.env.FAKE_HERDR_TRUST === '1') {
        const named = keys.map((k) => String(k).toLowerCase());
        s.trust = s.trust || 'no';
        if (s.trust === 'no' && named.includes('down')) s.trust = 'yes';
        else if (s.trust === 'yes' && named.includes('enter')) s.trust = 'done';
        else if (s.trust === 'no' && named.includes('enter')) killPrimary(s);
      }
      save(s);
      out({});
      break;
    }
    case 'pane run': {
      const text = a[3] ?? '';
      s.sends.push({ text, t: Date.now() });
      if (/claude --dangerously-skip-permissions/.test(text)) {
        startPrimary(s, text);
      } else if (text === '/exit') {
        s.exits += 1;
        killPrimary(s);
      } else if (process.env.FAKE_HERDR_SCRIPT) {
        const script = JSON.parse(readFileSync(process.env.FAKE_HERDR_SCRIPT, 'utf8'));
        const key = Object.keys(script).find((k) => text.includes(k));
        if (key) {
          const child = spawn(process.execPath, [fileURLToPath(import.meta.url), '--apply', JSON.stringify({ home: s.home, writes: script[key], sayText: text })], { detached: true, stdio: 'ignore', env: process.env, windowsHide: true });
          child.unref();
        }
      }
      save(s);
      out({});
      break;
    }
    case 'tab list': {
      // One tab per task record the home still holds, as firstmate's herdr backend keeps it.
      const state = s.home ? join(s.home, 'state') : null;
      const ids = state && existsSync(state) ? readdirSync(state).filter((f) => f.endsWith('.meta') && !f.startsWith('.')).map((f) => f.slice(0, -5)) : [];
      out({ tabs: ids.map((id) => ({ tab_id: `tab-${id}`, label: `fm-${id}`, workspace_id: 'ws-fake' })) });
      break;
    }
    default:
      fail(`fake herdr has no answer for ${verb}`, 2);
  }
}
