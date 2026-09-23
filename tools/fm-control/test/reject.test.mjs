import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const drive = join(root, "drive.mjs");
const fixtures = join(root, "test", "fixtures");

function run(trace, env = {}) {
  const marker = join(tmpdir(), `fm-control-herdr-spawn-${process.pid}-${Date.now()}`);
  const fake = join(tmpdir(), `fm-control-herdr-bin-${process.pid}-${Date.now()}.mjs`);
  writeFileSync(
    fake,
    `import { appendFileSync } from "node:fs";\nappendFileSync(${JSON.stringify(marker)}, "spawn\\n");\nprocess.exit(99);\n`,
  );
  const result = spawnSync(process.execPath, [drive, "run", trace], {
    encoding: "utf8",
    env: { ...process.env, ...env, FM_CONTROL_HERDR: fake },
  });
  return { result, marker };
}

const rejects = [
  ["pong-only.json", "pong"],
  ["bypass-only.json", "bypass"],
  ["lock-only.json", "lock"],
  ["unknown-until.json", "unknown"],
  ["mixed-pong.json", "pong mixed"],
];

for (const [file, label] of rejects) {
  test(`rejects ${label} with exit 2 and zero herdr spawns`, () => {
    const { result, marker } = run(join(fixtures, file));
    assert.equal(result.status, 2, result.stderr || result.stdout);
    assert.equal(result.stdout.trim(), "");
    assert.equal(existsSync(marker), false, "herdr binary was spawned");
  });
}

test("parse of a legal trace does not spawn herdr", () => {
  mkdirSync(join(tmpdir(), "fm-control-parse"), { recursive: true });
  const legal = join(tmpdir(), "fm-control-legal.json");
  writeFileSync(
    legal,
    JSON.stringify({
      feature: "ok",
      steps: [{ say: "ahoy", until: "registered" }],
    }),
  );
  const { result, marker } = run(legal);
  // run() would spawn; use parse
  const marker2 = join(tmpdir(), `fm-control-herdr-spawn-parse-${process.pid}`);
  const fake = join(tmpdir(), `fm-control-herdr-bin-parse-${process.pid}.mjs`);
  writeFileSync(
    fake,
    `import { appendFileSync } from "node:fs";\nappendFileSync(${JSON.stringify(marker2)}, "spawn\\n");\nprocess.exit(99);\n`,
  );
  const parsed = spawnSync(process.execPath, [drive, "parse", legal], {
    encoding: "utf8",
    env: { ...process.env, FM_CONTROL_HERDR: fake },
  });
  assert.equal(parsed.status, 0, parsed.stderr);
  assert.equal(existsSync(marker2), false);
  assert.ok(JSON.parse(parsed.stdout).feature === "ok");
  void result;
  void marker;
});
