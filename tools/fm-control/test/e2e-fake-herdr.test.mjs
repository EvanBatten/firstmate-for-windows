import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, unlinkSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { writeFakeJournalSays } from "./fake-herdr.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const drive = join(root, "drive.mjs");
const fakeBin = join(root, "test", "fake-herdr.mjs");
const trace = join(root, "traces", "restart-primary.json");

function startFake({ socket, journal }) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [fakeBin, "--serve", "--socket", socket, "--journal", journal], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    const timer = setTimeout(() => reject(new Error("fake herdr did not listen")), 5000);
    child.stdout.on("data", (d) => {
      if (String(d).includes("listening")) {
        clearTimeout(timer);
        resolve(child);
      }
    });
    child.on("error", reject);
    child.stderr.on("data", (d) => {
      process.stderr.write(d);
    });
  });
}

test("fake-herdr restart-primary: JSON shape, pass, each say once, zero herdr spawns", async () => {
  const socket = join(tmpdir(), `fm-control-fake-${process.pid}.sock`);
  const journal = join(tmpdir(), `fm-control-fake-${process.pid}.journal`);
  try {
    unlinkSync(socket);
  } catch {
    /* none */
  }
  const fake = await startFake({ socket, journal });
  try {
    const result = spawnSync(process.execPath, [drive, "run", trace], {
      encoding: "utf8",
      env: {
        ...process.env,
        FM_CONTROL_SOCKET: socket,
        FM_CONTROL_HERDR: join(tmpdir(), "fm-control-must-not-spawn"),
        FM_CONTROL_MODEL: "sonnet",
      },
      timeout: 60_000,
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    const json = JSON.parse(result.stdout);
    assert.equal(json.feature, "restart-primary");
    assert.equal(typeof json.wallMs, "number");
    assert.equal(typeof json.readyMs, "number");
    assert.equal(typeof json.predicateMs, "number");
    assert.equal(json.pass, true, JSON.stringify(json));
    assert.ok(Array.isArray(json.steps));
    assert.equal(json.steps.at(-1).until, "cleaned");
    assert.equal(json.steps.at(-1).ok, true);
    assert.equal(json.overhead.spawns, 0);
    assert.ok(json.overhead.herdrCalls >= 1);
    const says = writeFakeJournalSays(journal);
    assert.equal(says.length, 2, `says=${JSON.stringify(says)}`);
    assert.ok(says[0].startsWith("ahoy! add my project from "), says[0]);
    assert.ok(says[1].startsWith("ahoy, I'm back. carry on where we left off:"), says[1]);
    assert.ok(!says.includes("$relaunch"));
    assert.equal(existsSync(join(tmpdir(), "fm-control-must-not-spawn")), false);
  } finally {
    fake.kill("SIGTERM");
    try {
      unlinkSync(socket);
    } catch {
      /* ignore */
    }
  }
});
