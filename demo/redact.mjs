import { homedir, hostname, tmpdir, userInfo } from 'node:os';

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const GAP = '(?:\\x1b\\[[0-9;]*m|\\r?\\n[ ]*)*';
const GAP_RE = /\x1b\[[0-9;]*m|\r?\n[ ]*/g;
const wrapTolerant = (literal) => [...literal].map(esc).join(GAP);
const keepGaps = (match) => (match.match(GAP_RE) || []).join('');

const variants = (p) => {
  const fwd = p.replace(/\\/g, '/');
  const msys = fwd.replace(/^([A-Za-z]):/, (_, d) => `/${d.toLowerCase()}`);
  return [...new Set([p, fwd, msys])];
};

export function redactor({ user = userInfo().username, host = hostname(), home = homedir(), tmp = tmpdir(), scratchNames = [] } = {}) {
  const homeRel = tmp.startsWith(home) ? `~${tmp.slice(home.length)}` : null;
  const tmps = [...variants(tmp), ...(homeRel ? variants(homeRel) : [])];
  const literals = [];
  for (const name of scratchNames) {
    for (const t of [...tmps, '/tmp']) for (const sep of ['\\', '/']) literals.push([`${t}${sep}${name}`, '~/demo']);
  }
  for (const t of tmps) literals.push([t, '/tmp']);
  for (const h of variants(home)) literals.push([h, '~']);
  literals.push([`${user}@${host}`, 'captain@firstmate'], [host, 'firstmate'], [user, 'captain']);
  const rules = literals
    .sort((a, b) => b[0].length - a[0].length)
    .map(([lit, to]) => [new RegExp(wrapTolerant(lit), 'gi'), (m) => to + keepGaps(m)]);
  rules.push([/[A-Za-z]--Users-[\w-]*/g, 'scratch']);
  rules.push([/(~|\/tmp)((?:[\\/][\w.-]*)+)/g, (_, root, rest) => root + rest.replace(/\\/g, '/')]);
  const redact = (s) => rules.reduce((acc, [re, to]) => acc.replace(re, to), s);
  const leaks = (plain) => {
    const joined = plain.replace(/\s*\n\s*/g, '');
    return [user, host, 'AppData', 'Users', ...scratchNames.map((n) => n.slice(-6))]
      .filter((w) => joined.toLowerCase().includes(w.toLowerCase()));
  };
  return { redact, leaks };
}

export function scratchNamesIn(texts) {
  const names = new Set();
  for (const t of texts) for (const m of t.replace(/\x1b\[[0-9;]*m/g, '').matchAll(/fm-drive-[a-z-]+?-[A-Za-z0-9]{6}(?![A-Za-z0-9-])/g)) names.add(m[0]);
  return [...names];
}
