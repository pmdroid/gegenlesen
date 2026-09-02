import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { liveTranscriptLine, mapSessionUpdate } from "../lib/transcript.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = join(here, "fixtures");

const nestedTool = mapSessionUpdate({
  sessionUpdate: "tool_call",
  toolCall: { toolCallId: "tc-1", title: "read_file", status: "running" },
});
assert.equal(nestedTool?.kind, "tool_call");
assert.equal(nestedTool?.title, "read_file");
assert.equal(nestedTool?.toolCallId, "tc-1");

const flatTool = mapSessionUpdate({
  sessionUpdate: "tool_call",
  toolCallId: "tc-2",
  title: "write_file",
  status: "completed",
});
assert.equal(flatTool?.kind, "tool_call");
assert.equal(flatTool?.title, "write_file");
assert.equal(flatTool?.toolCallId, "tc-2");

const agentText = mapSessionUpdate({
  sessionUpdate: "agent_message_chunk",
  content: { type: "text", text: "Reviewing diff..." },
});
assert.equal(agentText?.kind, "agent_text");
assert.equal(agentText?.text, "Reviewing diff...");

const liveText = liveTranscriptLine(agentText);
assert.equal(liveText?.type, "text");
assert.equal(liveText?.part?.text, "Reviewing diff...");

const liveTool = liveTranscriptLine(flatTool);
assert.equal(liveTool?.type, "tool");
assert.equal(liveTool?.part?.tool, "write_file");
assert.equal(liveTool?.part?.state?.status, "completed");

const golden = readFileSync(join(fixtures, "acp-session-valid.jsonl"), "utf8")
  .trim()
  .split("\n")
  .map((line) => JSON.parse(line));
assert.ok(golden.some((entry) => entry.event === "permission_auto_approved"));
assert.ok(golden.some((entry) => entry.event === "prompt_finished" && entry.stopReason === "end_turn"));

console.log("transcript.test.mjs: ok");
