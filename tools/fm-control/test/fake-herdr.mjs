#!/usr/bin/env node
import {
  appendFileSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";

const home = process.env.FM_CONTROL_HOME;
const log = process.env.FM_CONTROL_FAKE_LOG;
let launches = 0;

function reply(id, result) {
  process.stdout.write(`${JSON.stringify({ id, result })}\n`);
}

function event(name, data) {
  process.stdout.write(`${JSON.stringify({ event: name, data })}\n`);
}

function setLock(identity) {
  mkdirSync(join(home, "state"), { recursive: true });
  writeFileSync(join(home, "state", ".lock"), `${identity}\n`);
}

function launch() {
  launches += 1;
  setLock(`fake-lock-${launches}`);
  queueMicrotask(() => {
    event("pane.agent_status_changed", {
      pane_id: "w1:p1",
      workspace_id: "w1",
      agent_status: "done",
      agent: "claude",
    });
    event("pane.output_matched", {
      pane_id: "w1:p1",
      matched_line: "bypass permissions on",
    });
  });
}

function registerProject(text) {
  const origin = /from ([^ ]+) as a local-only project/.exec(text)?.[1];
  const seed = origin
    ? readFileSync(join(origin, "refs", "heads", "main"), "utf8").trim()
    : "1".repeat(40);
  mkdirSync(join(home, "data"), { recursive: true });
  mkdirSync(join(home, "projects", "greeter", ".git", "refs", "heads"), { recursive: true });
  mkdirSync(join(home, "state"), { recursive: true });
  writeFileSync(join(home, "data", "projects.md"), "- greeter local-only yolo=off\n");
  writeFileSync(join(home, "projects", "greeter", ".git", "refs", "heads", "main"), `${seed}\n`);
  writeFileSync(
    join(home, "state", "fake-task.meta"),
    "kind=ship\nherdr_pane_id=w1:p2\n",
  );
}

function finishProject() {
  writeFileSync(
    join(home, "projects", "greeter", ".git", "refs", "heads", "main"),
    `${"b".repeat(40)}\n`,
  );
  rmSync(join(home, "state", "fake-task.meta"), { force: true });
  writeFileSync(join(home, "state", ".wake-queue"), "");
}

function handleInput(text) {
  if (text.startsWith("claude") || text.startsWith("claude.exe")) {
    launch();
    return;
  }
  if (text === "/exit") {
    queueMicrotask(() => {
      event("pane.agent_status_changed", {
        pane_id: "w1:p1",
        workspace_id: "w1",
        agent_status: "unknown",
        agent: null,
      });
      event("pane.output_matched", {
        pane_id: "w1:p1",
        matched_line: "$ ",
      });
    });
    return;
  }
  if (log) appendFileSync(log, `${JSON.stringify(text)}\n`);
  if (text.includes("add my project")) registerProject(text);
  if (text.includes("I'm back")) finishProject();
}

createInterface({ input: process.stdin }).on("line", (line) => {
  const request = JSON.parse(line);
  switch (request.method) {
    case "workspace.create":
      reply(request.id, {
        type: "workspace_created",
        workspace: { workspace_id: "w1" },
        root_pane: { pane_id: "w1:p1" },
      });
      break;
    case "events.subscribe":
      reply(request.id, { type: "subscription_started" });
      break;
    case "pane.send_input":
      reply(request.id, { type: "input_sent" });
      handleInput(request.params.text || "");
      break;
    case "pane.send_keys":
    case "workspace.focus":
    case "workspace.close":
      reply(request.id, { type: "ok" });
      break;
    default:
      reply(request.id, { type: "ok" });
  }
});
