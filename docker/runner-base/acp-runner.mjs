#!/usr/bin/env node
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { appendFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { liveTranscriptLine, mapSessionUpdate } from "./lib/transcript.mjs";
import { validateOutput } from "./lib/validate.mjs";
import { readWorkspaceTextFile, writeWorkspaceTextFile, WORKSPACE_ROOT } from "./lib/workspace-fs.mjs";
import { WorkspaceTerminalManager } from "./lib/workspace-terminal.mjs";
import { atomicWrite, judgeCandidateIDs, readSubmission } from "./lib/submission.mjs";
import { preparedInputs } from "./lib/prepared-inputs.mjs";

function parseArgs(argv) {
  const args = {
    timeoutSec: 900,
    setupTimeoutSec: 15,
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
    else if (arg === "--setup-timeout-sec") args.setupTimeoutSec = Number(argv[++i]);
    else if (arg === "--output") args.output = argv[++i];
    else if (arg === "--output-path") args.outputPath = argv[++i];
    else if (arg === "--validation-errors") args.validationErrors = argv[++i];
    else throw new Error(`unknown argument: ${arg}`);
  }
  args.command = argv.slice(i);
  if (args.command.length === 0) {
    throw new Error(
      "usage: acp-runner.mjs [--prompt-file path] [--prompt-uri uri] [--message text] [--transcript path] [--timeout-sec n] [--output findings|judge|mine|harvest|suggestion_judge|architecture] [--output-path path] [--validation-errors path] -- command args...",
    );
  }
  const outputKinds = new Set(["findings", "judge", "mine", "harvest", "suggestion_judge", "architecture"]);
  if (!outputKinds.has(args.output)) {
    throw new Error(`--output must be findings, judge, mine, harvest, suggestion_judge, or architecture, got ${args.output}`);
  }
  if (!Number.isFinite(args.timeoutSec) || args.timeoutSec <= 0) {
    throw new Error(`--timeout-sec must be a positive number, got ${args.timeoutSec}`);
  }
  if (!Number.isFinite(args.setupTimeoutSec) || args.setupTimeoutSec <= 0) {
    throw new Error("--setup-timeout-sec must be a positive number");
  }
  if (args.outputPath && !args.validationErrors) {
    args.validationErrors = join(dirname(args.outputPath), "validation_errors.json");
  }
  return args;
}

const args = parseArgs(process.argv);
if (args.transcript) writeFileSync(args.transcript, "");

try {
  mkdirSync("/home/gegenlesen/.claude/debug", { recursive: true });
} catch {}

function redact(text) {
  return text
    .replace(/sk-[A-Za-z0-9_-]+/g, "sk-REDACTED")
    .replace(/("api_key"\s*:\s*")[^"]*(")/gi, "$1REDACTED$2")
    .replace(/Bearer\s+[A-Za-z0-9._-]+/gi, "Bearer REDACTED");
}

function record(entry) {
  const line = redact(JSON.stringify({ ts: new Date().toISOString(), ...entry }));
  if (args.transcript) appendFileSync(args.transcript, line + "\n");
  if (entry.dir === "job_log") process.stdout.write(line + "\n");
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
  if (args.output === "architecture") {
    if (!raw.trim()) {
      const errors = [{ path: args.outputPath, message: "empty output file" }];
      writeValidationErrors(errors);
      return 4;
    }
    status(`accepted ${args.output} at ${args.outputPath}`);
    return 0;
  }
  if (args.output !== "findings" && args.output !== "judge") {
    try {
      JSON.parse(raw);
    } catch (error) {
      const errors = [{ path: "$", message: `invalid json: ${error.message}` }];
      writeValidationErrors(errors);
      status(`json parse failed for ${args.output}`);
      return 5;
    }
    status(`accepted ${args.output} at ${args.outputPath}`);
    return 0;
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

const submission = args.outputPath && ["findings", "judge"].includes(args.output) ? {
  kind: args.output,
  outputPath: args.outputPath,
  runID: randomUUID(),
  expectedIDs: judgeCandidateIDs(args.output, args.outputPath),
} : null;
if (submission) {
  rmSync(`${args.outputPath}.submitted`, { force: true });
  process.env.GEGENLESEN_OUTPUT_KIND = args.output;
  process.env.GEGENLESEN_OUTPUT_PATH = args.outputPath;
  process.env.GEGENLESEN_SUBMISSION_ID = submission.runID;
}
let acceptedResult = null;
let submissionTimer;

const child = spawn(args.command[0], args.command.slice(1), {
  stdio: ["pipe", "pipe", "pipe"],
});

let nextId = 1;
const pending = new Map();
let settled = false;
const executionDeadline = performance.now() + args.timeoutSec * 1000;
const setupDeadline = Math.min(executionDeadline, performance.now() + args.setupTimeoutSec * 1000);
let sessionId = null;
const terminals = new WorkspaceTerminalManager();

function finish(code, reason) {
  if (settled) return;
  settled = true;
  clearTimeout(timeout);
  clearInterval(submissionTimer);
  status(`finished: ${reason}`);
  record({ dir: "client", event: "finish", code, reason });
  if (acceptedResult !== null && sessionId && !child.stdin.destroyed) {
    send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId } });
  }
  const exitWithResult = () => {
    if (acceptedResult !== null) atomicWrite(args.outputPath, acceptedResult);
    process.exit(code === 0 ? validateResultFile() : code);
  };
  if (child.exitCode !== null || child.signalCode !== null) {
    exitWithResult();
    return;
  }
  try {
    child.stdin.end();
  } catch {}
  const killer = setTimeout(() => {
    try {
      child.kill("SIGKILL");
    } catch {}
  }, acceptedResult !== null ? 250 : 5000);
  killer.unref();
  child.once("exit", exitWithResult);
  setTimeout(exitWithResult, acceptedResult !== null ? 1000 : 7000).unref();
}

const timeout = setTimeout(() => {
  record({ dir: "client", event: "timeout", timeoutSec: args.timeoutSec });
  try {
    child.kill("SIGKILL");
  } catch {}
  finish(124, `timed out after ${args.timeoutSec}s`);
}, args.timeoutSec * 1000);
timeout.unref();

function acceptSubmission() {
  if (!submission || settled || performance.now() >= executionDeadline) return false;
  const raw = readSubmission(submission);
  if (raw === null) return false;
  acceptedResult = raw;
  record({ dir: "job_log", event: "result_submitted", output: args.output });
  finish(0, "validated result submitted");
  return true;
}

function send(message) {
  if (child.stdin.destroyed || child.stdin.writableEnded) return;
  record({ dir: "send", message });
  child.stdin.write(JSON.stringify(message) + "\n");
}

function request(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    if (method !== "session/prompt" && performance.now() >= setupDeadline) {
      reject(new Error(`${method}: setup deadline exceeded`));
      return;
    }
    const timer = method === "session/prompt" ? null : setTimeout(() => {
      pending.delete(id);
      reject(new Error(`${method}: setup deadline exceeded`));
    }, Math.max(0, setupDeadline - performance.now()));
    pending.set(id, { resolve, reject, method, timer });
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

async function configureSession(session) {
  const modes = session.modes?.availableModes ?? [];
  for (const preferred of ["bypassPermissions", "agent-full-access", "dontAsk", "default"]) {
    const match = modes.find((mode) => mode.id === preferred);
    if (!match) continue;
    try {
      await request("session/set_mode", { sessionId: session.sessionId, modeId: match.id });
      status(`session mode set: ${match.id}`);
      record({ dir: "job_log", event: "session_mode_set", modeId: match.id });
      break;
    } catch (error) {
      if (error.message.includes("setup deadline")) throw error;
      status(`session/set_mode ${match.id} failed: ${error.message}`);
    }
  }

  const codexModel = process.env.CODEX_ACP_MODEL?.trim();
  const cursorModel = process.env.CURSOR_ACP_MODEL?.trim() || process.env.CURSOR_MODEL?.trim();
  const grokModel = process.env.GROK_ACP_MODEL?.trim() || process.env.GROK_MODEL?.trim();
  const claudeModel = process.env.ANTHROPIC_MODEL?.trim();
  const modelId = codexModel || cursorModel || grokModel || claudeModel;
  if (!modelId) return;

  const modelOption = (session.configOptions ?? []).find(
    (entry) => entry?.category === "model" || (entry?.id ?? entry?.configId) === "model",
  );
  const configId = modelOption?.id ?? modelOption?.configId;
  let result;
  if (configId) {
    try {
      result = await request("session/set_config_option", {
        sessionId: session.sessionId,
        configId,
        value: modelId,
      });
    } catch (error) {
      if (error.message.includes("setup deadline")) throw error;
      status(`session/set_config_option failed: ${error.message}`);
    }
  }
  if (result === undefined) {
    result = await request("session/set_model", { sessionId: session.sessionId, modelId });
  }
  const confirmedOption = result?.configOptions?.find(
    (entry) => entry?.category === "model" || (entry?.id ?? entry?.configId) === configId,
  );
  const effectiveModelId = confirmedOption?.currentValue ?? result?.models?.currentModelId ?? null;
  const values = (modelOption?.options ?? []).flatMap((option) => option.options ?? [option]).map((option) => option.value);
  const alias = claudeModel === modelId ? /^(opus|sonnet|haiku)(\[1m\])?$/.exec(modelId) : null;
  const normalizedClaudeAlias = alias && !values.includes(modelId) && values.includes(effectiveModelId)
    && effectiveModelId.startsWith(`claude-${alias[1]}-`)
    && (!alias[2] || /(?:-1m|\[1m\])$/.test(effectiveModelId));
  if (effectiveModelId !== null && effectiveModelId !== modelId && !normalizedClaudeAlias) {
    throw new Error(`requested model ${modelId}, agent confirmed ${effectiveModelId}`);
  }
  status(`session model acknowledged: ${modelId}${effectiveModelId ? ` (confirmed ${effectiveModelId})` : ""}`);
  record({ dir: "job_log", event: "session_model_set", modelId, effectiveModelId });
}

function respondOk(id, result = null) {
  send({ jsonrpc: "2.0", id, result });
}

function respondError(id, message) {
  send({ jsonrpc: "2.0", id, error: { code: -32000, message } });
}

function handleIncoming(message) {
  if (settled) return;
  if (message.id !== undefined && message.method === undefined) {
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    clearTimeout(entry.timer);
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
    const update = message.params?.update ?? message.params;
    const mapped = mapSessionUpdate(update);
    if (mapped) record({ dir: "job_log", event: "session_update", ...mapped });
    const live = liveTranscriptLine(mapped);
    if (live) process.stdout.write(`${JSON.stringify(live)}\n`);
    return;
  }
  if (message.method === "fs/read_text_file") {
    try {
      const result = readWorkspaceTextFile(message.params?.path, message.params?.line, message.params?.limit);
      status(`fs read: ${message.params?.path}`);
      respondOk(message.id, result);
    } catch (error) {
      respondError(message.id, String(error.message ?? error));
    }
    return;
  }
  if (message.method === "fs/write_text_file") {
    try {
      writeWorkspaceTextFile(message.params?.path, message.params?.content ?? "");
      status(`fs write: ${message.params?.path}`);
      respondOk(message.id);
    } catch (error) {
      respondError(message.id, String(error.message ?? error));
    }
    return;
  }
  if (message.method === "terminal/create") {
    try {
      const result = terminals.create(message.params ?? {});
      status(`terminal create: ${message.params?.command} ${(message.params?.args ?? []).join(" ")}`.trim());
      respondOk(message.id, result);
    } catch (error) {
      respondError(message.id, String(error.message ?? error));
    }
    return;
  }
  if (message.method === "terminal/output") {
    try {
      respondOk(message.id, terminals.output(message.params?.terminalId));
    } catch (error) {
      respondError(message.id, String(error.message ?? error));
    }
    return;
  }
  if (message.method === "terminal/wait_for_exit") {
    terminals
      .waitForExit(message.params?.terminalId)
      .then((exitStatus) => respondOk(message.id, exitStatus))
      .catch((error) => respondError(message.id, String(error.message ?? error)));
    return;
  }
  if (message.method === "terminal/kill") {
    try {
      respondOk(message.id, terminals.kill(message.params?.terminalId));
    } catch (error) {
      respondError(message.id, String(error.message ?? error));
    }
    return;
  }
  if (message.method === "terminal/release") {
    try {
      respondOk(message.id, terminals.release(message.params?.terminalId));
    } catch (error) {
      respondError(message.id, String(error.message ?? error));
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

child.stdin.on("error", (error) => {
  if (!settled) finish(3, `agent input failed: ${error.message}`);
});

child.on("exit", (code, signal) => {
  record({ dir: "client", event: "agent-exit", code, signal });
  if (!settled && acceptSubmission()) return;
  for (const entry of pending.values()) {
    clearTimeout(entry.timer);
    entry.reject(new Error("agent exited before responding"));
  }
  pending.clear();
  if (!settled) {
    status(`agent exited early (code=${code} signal=${signal})`);
    process.exit(1);
  }
});

child.on("error", (error) => {
  record({ dir: "client", event: "spawn-error", error: String(error) });
  finish(127, `spawn failed: ${error}`);
});

try {
  const init = await request("initialize", {
    protocolVersion: 1,
    clientCapabilities: {
      fs: { readTextFile: true, writeTextFile: true },
      terminal: true,
    },
  });
  status(`initialized: protocolVersion=${init.protocolVersion}`);
  record({ dir: "job_log", event: "initialized", protocolVersion: init.protocolVersion });

  const session = await request("session/new", { cwd: WORKSPACE_ROOT, mcpServers: [] });
  sessionId = session.sessionId;
  status(`session created: ${sessionId}`);
  record({ dir: "job_log", event: "session_created", sessionId });
  await configureSession(session);

  const remainingSec = Math.max(1, Math.floor((executionDeadline - performance.now()) / 1000));
  const prompt = [{ type: "text", text: `${args.message}\nYou have at most ${remainingSec} seconds remaining. Finish and save the required JSON within this time.` }];
  if (args.promptFile) {
    prompt.push({ type: "text", text: readFileSync(args.promptFile, "utf8") });
  }
  const inputs = preparedInputs(args.output, args.outputPath);
  if (inputs) prompt.push({ type: "text", text: inputs });
  if (performance.now() >= setupDeadline) throw new Error("setup deadline exceeded");
  if (submission) {
    prompt.push({ type: "text", text: "When investigation is complete, submit the final JSON with node /opt/gegenlesen/acp-runner/submit-result.mjs using the JSON as standard input. This command validates and saves your result and ends the session. Correct any reported errors and resubmit. A saved file alone is only a checkpoint. Do not install validators, write validation scripts, reread the saved result, or produce a closing explanation. The host checks the format and source evidence." });
    submissionTimer = setInterval(acceptSubmission, 25);
    submissionTimer.unref();
  }
  const result = await request("session/prompt", { sessionId: session.sessionId, prompt });
  if (!settled && !acceptSubmission()) {
    if (submission) {
      finish(4, "model ended without submitting a complete result");
    } else {
      status(`prompt finished: stopReason=${result.stopReason}`);
      record({ dir: "job_log", event: "prompt_finished", stopReason: result.stopReason });
      finish(result.stopReason === "end_turn" ? 0 : 2, `stopReason=${result.stopReason}`);
    }
  }
} catch (error) {
  record({ dir: "client", event: "protocol-error", error: String(error) });
  finish(3, String(error));
}
