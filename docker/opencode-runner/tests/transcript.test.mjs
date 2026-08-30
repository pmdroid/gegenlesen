import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = join(here, "fixtures", "acp-session-valid.jsonl");

const lines = readFileSync(fixture, "utf8").trim().split("\n").map((line) => JSON.parse(line));
const jobLog = lines.filter((entry) => entry.dir === "job_log");

assert.ok(jobLog.some((e) => e.event === "initialized"));
assert.ok(jobLog.some((e) => e.event === "session_created"));
assert.ok(jobLog.some((e) => e.event === "permission_auto_approved"));
assert.ok(jobLog.some((e) => e.event === "session_update" && e.kind === "tool_call"));
assert.ok(jobLog.some((e) => e.event === "prompt_finished" && e.stopReason === "end_turn"));

console.log("transcript.test.mjs: ok");
