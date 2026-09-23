// The one herdr client of a run.
//
// Two transports speak the same logical methods (the socket API's own names,
// e.g. pane.send_input). `socket` opens one Unix-socket connection per request
// and spawns nothing after attach: herdr 0.7.4 (protocol 16) answers one
// request per connection and closes it, so a persistent connection is not on
// offer, but a connect+request round trip is about a millisecond and no
// process. `cli` spawns the herdr binary once per call with shell:false, no
// bash, no pwsh, no jq; it is the transport Node can use on Windows today,
// where net.connect() cannot open herdr's AF_UNIX socket (Node emulates local
// sockets with named pipes there). Both transports count every call and every
// process they start so the result JSON can report driver overhead.
//
// Environment:
//   FM_CONTROL_HERDR            herdr binary (default: herdr on PATH)
//   FM_CONTROL_HERDR_SESSION    named herdr session to use (default: HERDR_SESSION, else default)
//   FM_CONTROL_TRANSPORT        auto | socket | cli (default auto: cli on win32, socket elsewhere)
//   FM_CONTROL_START_SERVER     0 forbids starting a herdr server; default starts one only when no
//                               session was named and the default session is not running, under a
//                               throwaway fm-control-<random> name this run also stops

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

export class Herdr {
  constructor({ bin, session, socketPath, transport, ownServer, log }) {
    this.bin = bin;
    this.session = session;
    this.socketPath = socketPath;
    this.transport = transport;
    this.ownServer = ownServer; // { child } when this run started the server
    this.log = log ?? (() => {});
    this.counters = { calls: 0, spawns: ownServer ? 1 : 0, statusSpawns: 0 };
    this.subscriptions = new Set();
  }

  static async attach(env = process.env, opts = {}) {
    const bin = env.FM_CONTROL_HERDR || 'herdr';
    const want = (env.FM_CONTROL_TRANSPORT || 'auto').toLowerCase();
    if (!['auto', 'socket', 'cli'].includes(want)) throw new HerdrError(`FM_CONTROL_TRANSPORT must be auto, socket or cli, not ${want}`);
    let session = env.FM_CONTROL_HERDR_SESSION || env.HERDR_SESSION || '';
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
      if (env.FM_CONTROL_START_SERVER === '0') {
        throw new HerdrError(`herdr session ${session || 'default'} is not running and FM_CONTROL_START_SERVER=0 forbids starting one`);
      }
      if (named && env.FM_CONTROL_START_SERVER !== '1') {
        throw new HerdrError(`herdr session ${session} is not running; start it, or set FM_CONTROL_START_SERVER=1 to let this run start and stop it`);
      }
      if (!named) session = `fm-control-${randomBytes(4).toString('hex')}`;
      log(`starting a throwaway herdr server for session ${session}`);
      // Never let the server inherit a tmux marker: firstmate's runtime
      // auto-detection lets $TMUX win over HERDR_ENV, so a pane that saw
      // both would dispatch workers into the driver's tmux, not herdr.
      const serverEnv = { ...env, HERDR_SESSION: session };
      delete serverEnv.TMUX;
      delete serverEnv.TMUX_PANE;
      const child = spawn(bin, ['server', '--session', session], {
        env: serverEnv,
        stdio: 'ignore',
        shell: false,
        windowsHide: true,
        detached: false,
      });
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

  // One logical herdr call. Returns the parsed `result` object.
  async call(method, params = {}, { timeoutMs = 30_000 } = {}) {
    this.counters.calls += 1;
    if (this.transport === 'socket') {
      const msg = await socketRequest(this.socketPath, method, params, timeoutMs);
      if (msg.error) throw new HerdrError(`${method}: ${msg.error.message ?? JSON.stringify(msg.error)}`);
      return msg.result;
    }
    this.counters.spawns += 1;
    return cliCall(this.bin, method, params, this.session, this.env, timeoutMs);
  }

  // Event stream (socket transport only). onEvent receives { event, data }.
  // Returns a handle with close(). On the cli transport returns null: the
  // caller falls back to its own low-rate reads.
  subscribe(subscriptions, onEvent) {
    if (this.transport !== 'socket') return null;
    this.counters.calls += 1;
    const handle = { closed: false, sock: null, close() { this.closed = true; this.sock?.destroy(); } };
    const open = () => {
      if (handle.closed) return;
      const sock = net.connect(this.socketPath);
      handle.sock = sock;
      let buf = '';
      sock.on('connect', () => sock.write(JSON.stringify({ id: 'fm-control-subscribe', method: 'events.subscribe', params: { subscriptions } }) + '\n'));
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

  // Stops a server this run started and removes the session directory herdr
  // made for it, after copying its server log to keepLogAt when given. A
  // server that was already running is left exactly as found.
  async close({ keepLogAt } = {}) {
    for (const s of this.subscriptions) s.close();
    if (this.ownServer) {
      this.log(`stopping the throwaway herdr server for session ${this.ownServer.session}`);
      try {
        await this.call('server.stop', {}, { timeoutMs: 5000 });
      } catch {
        // fall through to the child kill
      }
      const { child } = this.ownServer;
      await Promise.race([new Promise((r) => child.once('exit', r)), sleep(3000)]);
      if (child.exitCode === null) child.kill('SIGKILL');
      const dir = this.socketPath ? dirname(this.socketPath) : '';
      if (dir && basename(dir) === this.ownServer.session && basename(dirname(dir)) === 'sessions') {
        if (keepLogAt) { try { copyFileSync(join(dir, 'herdr-server.log'), keepLogAt); } catch { /* no log */ } }
        try { rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ }
      }
    }
  }
}

// ---- socket transport -----------------------------------------------------

let seq = 0;
export function socketRequest(socketPath, method, params, timeoutMs) {
  return new Promise((resolve, reject) => {
    const id = `fm-control-${++seq}`;
    const sock = net.connect(socketPath);
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

// ---- cli transport --------------------------------------------------------

function sessionArgs(session) {
  return session ? ['--session', session] : [];
}

// A .mjs/.js/.cjs "binary" runs under this node, so a scripted stand-in for
// herdr works the same on every platform without a shebang.
function run(bin, args, env, timeoutMs) {
  const scripted = /\.(mjs|cjs|js)$/i.test(bin);
  return new Promise((resolve, reject) => {
    const child = scripted
      ? spawn(process.execPath, [bin, ...args], { env, stdio: ['ignore', 'pipe', 'pipe'], shell: false, windowsHide: true })
      : spawn(bin, args, { env, stdio: ['ignore', 'pipe', 'pipe'], shell: false, windowsHide: true });
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

// Map a socket method onto the herdr CLI verb that does the same thing.
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
