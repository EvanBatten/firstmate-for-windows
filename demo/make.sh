#!/usr/bin/env bash
# make.sh - drive one real firstmate session, record its panes, and render the README demo.
#
# Usage:
#   demo/make.sh                drive tools/fm-drive/traces/whole-session.json into demo/out/run, then render
#   demo/make.sh --run <dir>    render an earlier run (<dir>/rec/frames.jsonl and <dir>/evidence/captain.log)
#
# A fresh drive needs what tools/fm-drive needs: a logged-in claude, herdr, git and Node 20 or newer.
# It starts its own Herdr session, runs four Opus agents for about 20 minutes, and stops the session at the end.
# Rendering needs ffmpeg built with libx264 and libwebp, and Google Chrome (or FM_DEMO_CHROME=<chromium binary>).
# The renderer replaces the user name, host name, home and temp paths in every frame and fails if any survive.
#
# Output in demo/out/: firstmate-demo.mp4, demo.webp, and check/ with one still per second.
# Look at every still in check/, then copy demo.webp to assets/demo.webp.
set -euo pipefail

demo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$demo/.." && pwd)
out=$demo/out
run=

if [ "${1:-}" = --run ]; then
  run=$(cd "${2:?--run needs a directory}" && pwd)
fi

[ -d "$demo/node_modules" ] || (cd "$demo" && npm ci --no-audit --no-fund >/dev/null)

if [ -z "$run" ]; then
  run=$out/run
  rm -rf "$run"
  mkdir -p "$run/rec"
  tmp=$(node -p 'require("os").tmpdir()')
  command -v cygpath >/dev/null 2>&1 && tmp=$(cygpath -u "$tmp")
  session=fm-demo-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
  : >"$run/.started"
  (
    cd "$root"
    FM_DRIVE_HERDR_SESSION=$session FM_DRIVE_START_SERVER=1 FM_DRIVE_EVIDENCE="$run/evidence" \
      exec node tools/fm-drive/drive.mjs run tools/fm-drive/traces/whole-session.json
  ) >"$run/result.json" 2>"$run/driver.log" &
  driver=$!
  for _ in $(seq 1 600); do
    [ -f "$run/evidence/workspace.json" ] && break
    kill -0 "$driver" 2>/dev/null || break
    sleep 0.5
  done
  recorder=
  if [ -f "$run/evidence/workspace.json" ]; then
    pane=$(node -p 'require(process.argv[1]).pane_id' "$run/evidence/workspace.json")
    home=
    for d in "$tmp"/fm-drive-whole-session-*/firstmate; do
      [ -d "$d" ] && [ "$d" -nt "$run/.started" ] && { [ -z "$home" ] || [ "$d" -nt "$home" ]; } && home=$d
    done
    node "$demo/record.mjs" --out "$run/rec" --pane "$pane" --home "$home" --session "$session" >"$run/rec.log" 2>&1 &
    recorder=$!
  fi
  code=0
  wait "$driver" || code=$?
  : >"$run/rec/STOP"
  [ -n "$recorder" ] && wait "$recorder"
  herdr server stop --session "$session" >/dev/null 2>&1 || true
  herdr session delete "$session" >/dev/null 2>&1 || true
  if [ "$code" != 0 ]; then
    echo "make.sh: the drive failed with exit $code; see $run/result.json and $run/driver.log" >&2
    exit "$code"
  fi
fi

node "$demo/render.mjs" --run "$run" --out "$out"
