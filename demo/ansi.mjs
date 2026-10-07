const BASE = ['#1d1f21', '#cc6666', '#b5bd68', '#f0c674', '#81a2be', '#b294bb', '#8abeb7', '#c5c8c6',
  '#666666', '#d54e53', '#b9ca4a', '#e7c547', '#7aa6da', '#c397d8', '#70c0b1', '#eaeaea'];
const cube = (n) => {
  if (n < 16) return BASE[n];
  if (n >= 232) { const v = 8 + (n - 232) * 10; return `rgb(${v},${v},${v})`; }
  const i = n - 16; const c = (x) => (x ? 55 + x * 40 : 0);
  return `rgb(${c(Math.floor(i / 36))},${c(Math.floor(i / 6) % 6)},${c(i % 6)})`;
};
const html = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function apply(st, codes) {
  for (let i = 0; i < codes.length; i++) {
    const c = codes[i];
    if (c === 0) { st.fg = st.bg = null; st.b = st.d = st.i = st.u = st.inv = false; }
    else if (c === 1) st.b = true; else if (c === 2) st.d = true; else if (c === 3) st.i = true;
    else if (c === 4) st.u = true; else if (c === 7) st.inv = true;
    else if (c === 22) st.b = st.d = false; else if (c === 23) st.i = false;
    else if (c === 24) st.u = false; else if (c === 27) st.inv = false;
    else if (c >= 30 && c <= 37) st.fg = BASE[c - 30]; else if (c >= 90 && c <= 97) st.fg = BASE[c - 82];
    else if (c >= 40 && c <= 47) st.bg = BASE[c - 40]; else if (c >= 100 && c <= 107) st.bg = BASE[c - 92];
    else if (c === 39) st.fg = null; else if (c === 49) st.bg = null;
    else if (c === 38 || c === 48) {
      const col = codes[i + 1] === 2 ? `rgb(${codes[i + 2]},${codes[i + 3]},${codes[i + 4]})` : cube(codes[i + 2]);
      i += codes[i + 1] === 2 ? 4 : 2;
      if (c === 38) st.fg = col; else st.bg = col;
    }
  }
}

function style(st) {
  const fg = st.inv ? (st.bg || 'var(--term-bg)') : st.fg;
  const bg = st.inv ? (st.fg || 'var(--term-fg)') : st.bg;
  const css = [];
  if (fg) css.push(`color:${fg}`);
  if (bg) css.push(`background:${bg}`);
  if (st.b) css.push('font-weight:700');
  if (st.d) css.push('opacity:.6');
  if (st.i) css.push('font-style:italic');
  if (st.u) css.push('text-decoration:underline');
  return css.join(';');
}

export function ansiToHtmlLines(ansi) {
  const st = {};
  apply(st, [0]);
  return ansi.replace(/\r/g, '').split('\n').map((line) => {
    let out = '';
    let last = 0;
    const emit = (text) => { if (text) { const s = style(st); out += s ? `<span style="${s}">${html(text)}</span>` : html(text); } };
    for (const m of line.matchAll(/\x1b\[([0-9;]*)m/g)) {
      emit(line.slice(last, m.index));
      apply(st, m[1] === '' ? [0] : m[1].split(';').map(Number));
      last = m.index + m[0].length;
    }
    emit(line.slice(last));
    return out;
  });
}
