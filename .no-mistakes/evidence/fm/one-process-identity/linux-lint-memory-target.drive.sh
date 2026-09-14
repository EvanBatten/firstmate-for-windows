export PATH="$HOME/bin:$PATH"
B=/tmp/nm-01M2EGJ8
cd "$B/target" || exit 1
echo "== tree: target 206a3b7 (fix + narrowed comments)"
echo "== host: $(uname -sr), $(nproc) vCPU, MemTotal $(awk '/MemTotal/{print $2}' /proc/meminfo) KiB"
for root in bin/fm-teardown.sh bin/fm-watch.sh; do
  tel="$B/tel-target-$(basename "$root" .sh).tsv"
  rm -f "$tel"
  echo "== bin/fm-lint.sh --jobs 1 --telemetry <tsv> $root"
  start=$(date +%s)
  bin/fm-lint.sh --jobs 1 --telemetry "$tel" "$root"
  rc=$?
  echo "exit=$rc wall=$(( $(date +%s) - start ))s"
  echo "-- telemetry:"
  cat "$tel"
  echo
done
