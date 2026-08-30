#!/usr/bin/env node
import { spawn } from "node:child_process";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { mapSessionUpdate } from "./lib/transcript.mjs";
import { validateOutput } from "./lib/validate.mjs";

function parseArgs(argv) {
  const args = {
    timeoutSec: 900,
    message: "Investigate the change thoroughly, then write findings as instructed.",
    output: "findings",
  };
  let i = 2;
  for (; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--") {
      i += 1;
      break;
    }
    if (arg === "--prompt-file") args.promptFile = argv[++i];
    else if (arg === "--prompt-uri") args.promptUri = argv[++i];
    else if (arg === "--message") args.message = argv[++i];
    else if (arg === "--transcript") args.transcript = argv[++i];
    else if (arg === "--timeout-sec") args.timeoutSec = Number(argv[++i]);
    else if (arg === "--output") args.output = argv[++i];
    else if (arg === "--output-path") args.outputPath = argv[++i];
    else if (arg === "--validation-errors") args.validationErrors = argv[++i];
    else throw new Error(`unknown argument: ${arg}`);
  }
  args.command = argv.slice(i);
  if (args.command.length === 0) {
    throw new Error(
      "usage: acp-runner.mjs [--prompt-file path] [--prompt-uri uri] [--message text] [--transcript path] [--timeout-sec n] [--output findings|judge] [--output-path path] [--validation-errors path] -- command args...",
    );
  }
  if (args.output !== "findings" && args.output !== "judge") {
    throw new Error(`--output must be findings or judge, got ${args.output}`);
  }
  if (!Number.isFinite(args.timeoutSec) || args.timeoutSec <= 0) {
    throw new Error(`--timeout-sec must be a positive number, got ${args.timeoutSec}`);
  }
  if (args.outputPath && !args.validationErrors) {
    args.validationErrors = join(dirname(args.outputPath), "validation_errors.json");
  }
  return args;
}

const args = parseArgs(process.argv);
if (args.transcript) writeFileSync(args.transcript, "");

function redact(text) {
  return text
    .replace(/sk-[A-Za-z0-9_-]+/g, "sk-REDACTED")
    .replace(/("api_key"\s*:\s*")[^"]*(")/gi, "$1REDACTED$2")
    .replace(/Bearer\s+[A-Za-z0-9._-]+/gi, "Bearer REDACTED");
}

function record(entry) {
  const line = redact(JSON.stringify({ ts: new Date().toISOString(), ...entry }));
  if (args.transcript) appendFileSync(args.transcript, line + "\n");
}

function status(text) {
  process.stderr.write(`[acp-runner] ${text}\n`);
}

function writeValidationErrors(errors) {
  if (!args.validationErrors) return;
  writeFileSync(args.validationErrors, JSON.stringify({ errors }, null, 2) + "\n");
}

function validateResultFile() {
  if (!args.outputPath) {
    status("no --output-path; skipping schema validation");
    return 0;
  }
  let raw;
  try {
    raw = readFileSync(args.outputPath, "utf8");
  } catch (error) {
    const errors = [{ path: args.outputPath, message: `missing output file: ${error.message}` }];
    writeValidationErrors(errors);
    return 4;
  }
  const errors = validateOutput(args.output, raw);
  if (errors.length > 0) {
    writeValidationErrors(errors);
    status(`schema validation failed (${errors.length} errors)`);
    return 5;
  }
  status(`validated ${args.output} at ${args.outputPath}`);
  return 0;
}

const child = spawn(args.command[0], args.command.slice(1), {
  stdio: ["pipe", "pipe", "pipe"],
});

let nextId = 1;
const pending = new Map();
let settled = false;

function finish(code, reason) {
  if (settled) return;
  settled = true;
  status(`finished: ${reason}`);
  record({ dir: "client", event: "finish", code, reason });
  try {
    child.stdin.end();
  } catch {}
  const killer = setTimeout(() => {
    try {
      child.kill("SIGKILL");
    } catch {}
  }, 5000);
  killer.unref();
  child.once("exit", () => {
    if (code !== 0) {
      process.exit(code);
      return;
    }
    process.exit(validateResultFile());
  });
  setTimeout(() => process.exit(code === 0 ? validateResultFile() : code), 7000).unref();
}

const timeout = setTimeout(() => {
  record({ dir: "client", event: "timeout", timeoutSec: args.timeoutSec });
  try {
    child.kill("SIGKILL");
  } catch {}
  finish(124, `timed out after ${args.timeoutSec}s`);
}, args.timeoutSec * 1000);
timeout.unref();

function send(message) {
  record({ dir: "send", message });
  child.stdin.write(JSON.stringify(message) + "\n");
}

function request(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject, method });
    send({ jsonrpc: "2.0", id, method, params });
  });
}

function pickPermissionOption(options) {
  for (const kind of ["allow_always", "allow_once"]) {
    const match = (options ?? []).find((option) => option.kind === kind);
    if (match) return match;
  }
  return (options ?? [])[0];
}

function handleIncoming(message) {
  if (message.id !== undefined && message.method === undefined) {
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    if (message.error) entry.reject(new Error(`${entry.method}: ${JSON.stringify(message.error)}`));
    else entry.resolve(message.result);
    return;
  }
  if (message.method === "session/request_permission") {
    const option = pickPermissionOption(message.params?.options);
    const title = message.params?.toolCall?.title ?? message.params?.toolCall?.toolCallId ?? "unknown tool";
    status(`auto-approving permission for ${title}`);
    record({
      dir: "job_log",
      event: "permission_auto_approved",
      toolCallId: message.params?.toolCall?.toolCallId,
      title,
      optionId: option?.optionId ?? null,
    });
    if (option) {
      send({ jsonrpc: "2.0", id: message.id, result: { outcome: { outcome: "selected", optionId: option.optionId } } });
    } else {
      send({ jsonrpc: "2.0", id: message.id, result: { outcome: { outcome: "cancelled" } } });
    }
    return;
  }
  if (message.method === "session/update") {
    const mapped = mapSessionUpdate(message.params?.update);
    if (mapped) record({ dir: "job_log", event: "session_update", ...mapped });
    if (message.params?.update?.sessionUpdate === "agent_message_chunk" && message.params.update.content?.type === "text") {
      process.stderr.write(message.params.update.content.text);
    }
    return;
  }
  if (message.id !== undefined) {
    send({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: `method not supported: ${message.method}` } });
  }
}

let buffered = "";
child.stdout.on("data", (chunk) => {
  buffered += chunk.toString("utf8");
  let newline = buffered.indexOf("\n");
  while (newline >= 0) {
    const line = buffered.slice(0, newline).trim();
    buffered = buffered.slice(newline + 1);
    newline = buffered.indexOf("\n");
    if (!line) continue;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      record({ dir: "recv", raw: line });
      continue;
    }
    record({ dir: "recv", message });
    handleIncoming(message);
  }
});

child.stderr.on("data", (chunk) => {
  record({ dir: "agent-stderr", text: chunk.toString("utf8") });
});

child.on("exit", (code, signal) => {
  record({ dir: "client", event: "agent-exit", code, signal });
  if (!settled) finish(code === 0 ? 0 : 1, `agent exited early (code=${code} signal=${signal})`);
});

child.on("error", (error) => {
  record({ dir: "client", event: "spawn-error", error: String(error) });
  finish(127, `spawn failed: ${error}`);
});

try {
  const init = await request("initialize", {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
  });
  status(`initialized: protocolVersion=${init.protocolVersion}`);
  record({ dir: "job_log", event: "initialized", protocolVersion: init.protocolVersion });

  const session = await request("session/new", { cwd: "/workspace", mcpServers: [] });
  status(`session created: ${session.sessionId}`);
  record({ dir: "job_log", event: "session_created", sessionId: session.sessionId });

  const prompt = [{ type: "text", text: args.message }];
  if (args.promptFile) {
    prompt.push({
      type: "resource",
      resource: {
        uri: args.promptUri ?? `file://${args.promptFile}`,
        mimeType: "text/markdown",
        text: readFileSync(args.promptFile, "utf8"),
      },
    });
  }
  const result = await request("session/prompt", { sessionId: session.sessionId, prompt });
  status(`prompt finished: stopReason=${result.stopReason}`);
  record({ dir: "job_log", event: "prompt_finished", stopReason: result.stopReason });
  finish(result.stopReason === "end_turn" ? 0 : 2, `stopReason=${result.stopReason}`);
} catch (error) {
  record({ dir: "client", event: "protocol-error", error: String(error) });
  finish(3, String(error));
}
