// Usage: node herdr-api.mjs <socket-path> <method> <params-json>
// Sends one request to a herdr server and prints its JSON response line.
//
// Herdr's CLI has no command for some socket methods, such as layout.apply.
// On Windows the "socket" herdr reports is a named pipe of the same name.
import net from 'node:net';

const [socketPath, method, params] = process.argv.slice(2);
const sock = net.connect(`\\\\.\\pipe\\${socketPath}`);
let buf = '';
const timer = setTimeout(() => { console.error(`herdr ${method}: no response within 15 s`); process.exit(1); }, 15_000);
sock.on('connect', () => sock.write(`${JSON.stringify({ id: `fm-win:${method}`, method, params: JSON.parse(params) })}\n`));
sock.on('data', (d) => {
  buf += d;
  const i = buf.indexOf('\n');
  if (i < 0) return;
  clearTimeout(timer);
  sock.destroy();
  const line = buf.slice(0, i);
  const failed = Boolean(JSON.parse(line).error);
  (failed ? process.stderr : process.stdout).write(`${line}\n`);
  process.exitCode = failed ? 1 : 0;
});
sock.on('error', (err) => { console.error(`herdr ${method}: ${err.message}`); process.exit(1); });
