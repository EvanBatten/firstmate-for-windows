import { test } from "node:test";
import assert from "node:assert/strict";
import { atShellPrompt } from "../lib/herdr.mjs";
import { waitUntil } from "../lib/wait.mjs";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

test("atShellPrompt matches Git Bash, Linux cwd, and Windows shells", () => {
  assert.equal(atShellPrompt("$"), true);
  assert.equal(atShellPrompt("$ "), true);
  assert.equal(atShellPrompt("firstmate $"), true);
  assert.equal(atShellPrompt("claude --resume abc\nfirstmate $"), true);
  assert.equal(atShellPrompt("PS C:\\Users\\me\\firstmate>"), true);
  assert.equal(atShellPrompt("C:\\Users\\me\\firstmate>"), true);
  assert.equal(atShellPrompt("bypass permissions on"), false);
  assert.equal(atShellPrompt("Welcome to Claude\n"), false);
  assert.equal(atShellPrompt(""), false);
});

test("waitUntil fails at once when the primary is already dead", async () => {
  const home = join(tmpdir(), `fm-control-dead-${process.pid}`);
  rmSync(home, { recursive: true, force: true });
  mkdirSync(join(home, "state"), { recursive: true });
  writeFileSync(join(home, "state", "keep"), "x\n");
  const started = Date.now();
  const result = await waitUntil({
    home,
    until: "dispatched",
    budgetMs: 5_000,
    stamps: {},
    isDead: () => true,
  });
  assert.equal(result.ok, false);
  assert.equal(result.dead, true);
  assert.ok(Date.now() - started < 200, `dead wait took ${Date.now() - started}ms`);
});
