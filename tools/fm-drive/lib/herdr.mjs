// On Windows herdr's socket is a named pipe of the reported name, and auto picks the cli transport there.
// layout.apply has no CLI verb, so it always goes over the socket.
//
// Environment:
//   FM_DRIVE_HERDR            herdr binary (default: herdr on PATH)
//   FM_DRIVE_HERDR_SESSION    named herdr session to use (default: HERDR_SESSION, else default)
//   FM_DRIVE_TRANSPORT        auto | socket | cli (default auto: cli on win32, socket elsewhere)
//   FM_DRIVE_START_SERVER     0 forbids starting a herdr server; default starts one only when no
//                               session was named and the default session is not running, under a
//                               throwaway fm-drive-<random> name this run also stops

import net from 'node:net';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { copyFileSync, rmSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';

export class HerdrError extends Error {
  constructor(message, { exitCode = 3 } = {}) {
    super(message);
    this.name = 'HerdrError';
    this.exitCode = exitCode;
  }
}

const CLI_SOURCE = { recent_unwrapped: 'recent-unwrapped', recent: 'recent', visible: 'visible', detection: 'detection' };

// Git Bash prints a lone `$`. Linux bash prints `firstmate $`.
// Windows pwsh prints `PS C:\path>` and cmd prints `C:\path>`.
export function atShellPrompt(text) {
  const t = String(text || '').replace(/\r/g, '').replace(/\s+$/g, '');
  if (!t) return false;
  const last = t.split('\n').pop() || '';
  return (
    last === '$' ||
    / \$ *$/.test(last) ||
    /^PS .*> *$/.test(last) ||
    /^[A-Za-z]:\\[^>]*> *$/.test(last)
  );
}

// Every pane of a server the driver starts inherits the server's environment, so
// the server starts from what a captain's fresh terminal holds. These variables
// come only from the shell that runs the driver.
const DRIVER_ONLY_ENV = [
  // Claude Code marks the shells it runs tools in. CLAUDE_CODE_CHILD_SESSION
  // turns transcript saving off, and the messaging pair reaches the driving agent.
  // The OAuth token is the driver's auth input, so it stays.
  (k) => k.startsWith('CLAUDE_CODE_') && k !== 'CLAUDE_CODE_OAUTH_TOKEN',
  (k) => ['CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_EFFORT', 'AI_AGENT'].includes(k),
  // Claude Code sets GIT_EDITOR=true for its tool shells; a captain's git opens their editor.
  (k) => k === 'GIT_EDITOR',
  // FM_DRIVE_* are the driver's inputs, and any other FM_* belongs to a firstmate
  // session around the driver. The driver passes the pane its own FM_PANE_PATH.
  (k) => k.startsWith('FM_'),
  // The driving shell's own herdr pane identity. herdr gives each pane its own,
  // and the driver names the session.
  (k) => k.startsWith('HERDR_'),
  // firstmate's runtime detection lets $TMUX win over HERDR_ENV, so a pane that
  // saw both would dispatch workers into the driver's tmux, not herdr.
  (k) => k === 'TMUX' || k === 'TMUX_PANE',
];

function captainEnv(env) {
  return Object.fromEntries(Object.entries(env).filter(([k]) => !DRIVER_ONLY_ENV.some((driverOnly) => driverOnly(k))));
}

export class Herdr {
  constructor({ bin, session, socketPath, transport, ownServer, log }) {
    this.bin = bin;
    this.session = session;
    this.socketPath = socketPath;
    this.transport = transport;
    this.ownServer = ownServer;
    this.log = log ?? (() => {});
    this.counters = { calls: 0, spawns: ownServer ? 1 : 0, statusSpawns: 0 };
    this.subscriptions = new Set();
  }

  static async attach(env = process.env, opts = {}) {
    const bin = env.FM_DRIVE_HERDR || 'herdr';
    const want = (env.FM_DRIVE_TRANSPORT || 'auto').toLowerCase();
    if (!['auto', 'socket', 'cli'].includes(want)) throw new HerdrError(`FM_DRIVE_TRANSPORT must be auto, socket or cli, not ${want}`);
    let session = env.FM_DRIVE_HERDR_SESSION || env.HERDR_SESSION || '';
    const named = session !== '';
    const log = opts.log ?? (() => {});
    let ownServer = null;
    let spawns = 0;

    let status = await cliJson(bin, ['status', '--json'], session, env).catch((err) => {
      throw new HerdrError(`herdr is not usable (${bin}): ${err.message}`);
    });
    spawns += 1;
    let running = Boolean(status?.server?.running);
    if (!running) {
      if (env.FM_DRIVE_START_SERVER === '0') {
        throw new HerdrError(`herdr session ${session || 'default'} is not running and FM_DRIVE_START_SERVER=0 forbids starting one`);
      }
      if (named && env.FM_DRIVE_START_SERVER !== '1') {
        throw new HerdrError(`herdr session ${session} is not running; start it, or set FM_DRIVE_START_SERVER=1 to let this run start and stop it`);
      }
      if (!named) session = `fm-drive-${randomBytes(4).toString('hex')}`;
      log(`starting a throwaway herdr server for session ${session}`);
      const serverEnv = { ...captainEnv(env), HERDR_SESSION: session };
      const child = spawnHerdr(bin, ['server', '--session', session], serverEnv, 'ignore');
      child.on('error', () => {});
      ownServer = { child, session };
      spawns += 1;
      const deadline = Date.now() + 30_000;
      while (Date.now() < deadline) {
        await sleep(150);
        status = await cliJson(bin, ['status', '--json'], session, env).catch(() => null);
        spawns += 1;
        if (status?.server?.running) { running = true; break; }
      }
      if (!running) {
        child.kill();
        throw new HerdrError(`herdr server for session ${session} did not report running within 30 s`);
      }
    }
    const socketPath = status?.server?.socket || env.HERDR_SOCKET_PATH || '';
    const protocol = status?.server?.protocol ?? status?.client?.protocol;
    if (typeof protocol === 'number' && protocol < 16) throw new HerdrError(`herdr protocol ${protocol} is below the floor 16`);

    let transport = want;
    if (transport === 'auto') transport = process.platform === 'win32' ? 'cli' : 'socket';
    if (transport === 'socket') {
      if (!socketPath) throw new HerdrError('herdr reported no socket path, so the socket transport cannot attach');
      try {
        await socketRequest(socketPath, 'ping', {}, 5000);
      } catch (err) {
        if (want === 'socket') throw new HerdrError(`cannot reach the herdr socket ${socketPath}: ${err.message}`);
        log(`socket transport unavailable (${err.message}); falling back to the herdr CLI`);
        transport = 'cli';
      }
    }
    const h = new Herdr({ bin, session, socketPath, transport, ownServer, log });
    h.counters.spawns = spawns;
    h.counters.statusSpawns = spawns - (ownServer ? 1 : 0);
    h.protocol = protocol;
    h.version = status?.server?.version ?? status?.client?.version ?? null;
    h.env = env;
    return h;
  }

  async call(method, params = {}, { timeoutMs = 30_000 } = {}) {
    this.counters.calls += 1;
    if (this.transport === 'socket' || SOCKET_ONLY.has(method)) {
      const msg = await socketRequest(this.socketPath, method, params, timeoutMs);
      if (msg.error) throw new HerdrError(`${method}: ${msg.error.message ?? JSON.stringify(msg.error)}`);
      return msg.result;
    }
    this.counters.spawns += 1;
    return cliCall(this.bin, method, params, this.session, this.env, timeoutMs);
  }

  subscribe(subscriptions, onEvent) {
    if (this.transport !== 'socket') return null;
    this.counters.calls += 1;
    const handle = { closed: false, sock: null, close() { this.closed = true; this.sock?.destroy(); } };
    const open = () => {
      if (handle.closed) return;
      const sock = net.connect(pipePath(this.socketPath));
      handle.sock = sock;
      let buf = '';
      sock.on('connect', () => sock.write(JSON.stringify({ id: 'fm-drive-subscribe', method: 'events.subscribe', params: { subscriptions } }) + '\n'));
      sock.on('data', (d) => {
        buf += d;
        let i;
        while ((i = buf.indexOf('\n')) >= 0) {
          const line = buf.slice(0, i); buf = buf.slice(i + 1);
          if (!line.trim()) continue;
          let msg;
          try { msg = JSON.parse(line); } catch { continue; }
          if (msg.event) onEvent(msg);
        }
      });
      sock.on('error', () => {});
      sock.on('close', () => { if (!handle.closed) setTimeout(open, 500); });
    };
    open();
    this.subscriptions.add(handle);
    return handle;
  }

  async close({ keepLogAt } = {}) {
    for (const s of this.subscriptions) s.close();
    if (this.ownServer) {
      this.log(`stopping the throwaway herdr server for session ${this.ownServer.session}`);
      try {
        await this.call('server.stop', {}, { timeoutMs: 5000 });
      } catch {}
      const { child } = this.ownServer;
      await Promise.race([new Promise((r) => child.once('exit', r)), sleep(3000)]);
      if (child.exitCode === null) child.kill('SIGKILL');
      const dir = this.socketPath ? dirname(this.socketPath) : '';
      if (dir && basename(dir) === this.ownServer.session && basename(dirname(dir)) === 'sessions') {
        if (keepLogAt) { try { copyFileSync(join(dir, 'herdr-server.log'), keepLogAt); } catch {} }
        try { rmSync(dir, { recursive: true, force: true }); } catch {}
      }
    }
  }
}

let seq = 0;
const SOCKET_ONLY = new Set(['layout.apply']);
const pipePath = (p) => (process.platform === 'win32' ? `\\\\.\\pipe\\${p}` : p);

export function socketRequest(socketPath, method, params, timeoutMs) {
  return new Promise((resolve, reject) => {
    const id = `fm-drive-${++seq}`;
    const sock = net.connect(pipePath(socketPath));
    let buf = '';
    let done = false;
    const finish = (fn, v) => { if (!done) { done = true; clearTimeout(timer); sock.destroy(); fn(v); } };
    const timer = setTimeout(() => finish(reject, new Error(`${method} timed out after ${timeoutMs} ms`)), timeoutMs);
    sock.on('connect', () => sock.write(JSON.stringify({ id, method, params }) + '\n'));
    sock.on('error', (err) => finish(reject, err));
    sock.on('data', (d) => {
      buf += d;
      const i = buf.indexOf('\n');
      if (i >= 0) {
        try { finish(resolve, JSON.parse(buf.slice(0, i))); } catch (err) { finish(reject, err); }
      }
    });
    sock.on('close', () => finish(reject, new Error(`${method}: herdr closed the connection without a response`)));
  });
}

function sessionArgs(session) {
  return session ? ['--session', session] : [];
}

// A .mjs/.js/.cjs "binary" runs under this node, so a scripted stand-in for
// herdr works the same on every platform without a shebang.
function spawnHerdr(bin, args, env, stdio) {
  const opts = { env, stdio, shell: false, windowsHide: true };
  return /\.(mjs|cjs|js)$/i.test(bin) ? spawn(process.execPath, [bin, ...args], opts) : spawn(bin, args, opts);
}

function run(bin, args, env, timeoutMs) {
  return new Promise((resolve, reject) => {
    const child = spawnHerdr(bin, args, env, ['ignore', 'pipe', 'pipe']);
    let out = '';
    let err = '';
    const timer = setTimeout(() => { child.kill(); reject(new Error(`herdr ${args[0]} ${args[1] ?? ''} timed out after ${timeoutMs} ms`)); }, timeoutMs);
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { err += d; });
    child.on('error', (e) => { clearTimeout(timer); reject(e); });
    child.on('close', (code) => { clearTimeout(timer); resolve({ code, out, err }); });
  });
}

async function cliJson(bin, args, session, env, timeoutMs = 15_000) {
  const r = await run(bin, [...args, ...sessionArgs(session)], { ...env, ...(session ? { HERDR_SESSION: session } : {}) }, timeoutMs);
  const text = r.out.trim() || r.err.trim();
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`herdr ${args.join(' ')} exited ${r.code}: ${text.slice(0, 300)}`);
  }
}

export function cliArgv(method, params) {
  const p = params;
  switch (method) {
    case 'ping': return ['status', '--json'];
    case 'workspace.list': return ['workspace', 'list'];
    case 'workspace.create': {
      const a = ['workspace', 'create'];
      if (p.cwd) a.push('--cwd', p.cwd);
      if (p.label) a.push('--label', p.label);
      for (const [k, v] of Object.entries(p.env ?? {})) a.push('--env', `${k}=${v}`);
      a.push(p.focus ? '--focus' : '--no-focus');
      return a;
    }
    case 'workspace.close': return ['workspace', 'close', p.workspace_id];
    case 'workspace.focus': return ['workspace', 'focus', p.workspace_id];
    case 'tab.list': return ['tab', 'list'];
    case 'tab.close': return ['tab', 'close', p.tab_id];
    case 'pane.get': return ['pane', 'get', p.pane_id];
    case 'pane.process_info': return ['pane', 'process-info', '--pane', p.pane_id];
    case 'pane.send_input': {
      const keys = p.keys ?? [];
      if (p.text !== undefined && keys.length === 1 && keys[0] === 'enter') return ['pane', 'run', p.pane_id, p.text];
      if (p.text !== undefined && keys.length === 0) return ['pane', 'send-text', p.pane_id, p.text];
      if (p.text === undefined && keys.length > 0) return ['pane', 'send-keys', p.pane_id, ...keys];
      throw new HerdrError('pane.send_input with text plus non-enter keys has no single CLI verb');
    }
    case 'pane.send_keys': return ['pane', 'send-keys', p.pane_id, ...p.keys];
    case 'pane.read': {
      const a = ['pane', 'read', p.pane_id, '--source', CLI_SOURCE[p.source] ?? p.source];
      if (p.lines) a.push('--lines', String(p.lines));
      return a;
    }
    case 'pane.wait_for_output': {
      const a = ['wait', 'output', p.pane_id, '--match', p.match.value, '--source', CLI_SOURCE[p.source] ?? p.source];
      if (p.match.type === 'regex') a.push('--regex');
      if (p.lines) a.push('--lines', String(p.lines));
      if (p.timeout_ms) a.push('--timeout', String(p.timeout_ms));
      return a;
    }
    case 'server.stop': return ['server', 'stop'];
    default:
      throw new HerdrError(`no CLI mapping for ${method}`);
  }
}

async function cliCall(bin, method, params, session, env, timeoutMs) {
  const argv = cliArgv(method, params);
  const r = await run(bin, [...argv, ...sessionArgs(session)], { ...env, ...(session ? { HERDR_SESSION: session } : {}) }, timeoutMs + 5000);
  if (method === 'pane.read') {
    if (r.code !== 0) throw new HerdrError(`pane.read exited ${r.code}: ${r.err.trim().slice(0, 300)}`);
    return { type: 'pane_read', read: { pane_id: params.pane_id, text: r.out } };
  }
  const text = r.out.trim() || r.err.trim();
  let msg;
  try {
    msg = JSON.parse(text);
  } catch {
    if (r.code === 0) return { type: 'ok', raw: text };
    throw new HerdrError(`herdr ${argv.slice(0, 2).join(' ')} exited ${r.code}: ${text.slice(0, 300)}`);
  }
  if (msg.error) throw new HerdrError(`${method}: ${msg.error.message ?? JSON.stringify(msg.error)}`);
  return msg.result ?? msg;
}

export function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}
