import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { mapSessionUpdate } from "../lib/transcript.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = join(here, "fixtures");

const toolCall = mapSessionUpdate({
  sessionUpdate: "tool_call",
  toolCall: { toolCallId: "tc-1", title: "read_file", status: "running" },
});
assert.equal(toolCall?.kind, "tool_call");
assert.equal(toolCall?.title, "read_file");

const agentText = mapSessionUpdate({
  sessionUpdate: "agent_message_chunk",
  content: { type: "text", text: "Reviewing diff..." },
});
assert.equal(agentText?.kind, "agent_text");
assert.equal(agentText?.text, "Reviewing diff...");

const golden = readFileSync(join(fixtures, "acp-session-valid.jsonl"), "utf8")
  .trim()
  .split("\n")
  .map((line) => JSON.parse(line));
assert.ok(golden.some((entry) => entry.event === "permission_auto_approved"));
assert.ok(golden.some((entry) => entry.event === "prompt_finished" && entry.stopReason === "end_turn"));

console.log("transcript.test.mjs: ok");
