#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import { accessSync, constants as fsConstants, cpSync, mkdtempSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function isRunnable(path) {
  try {
    accessSync(path, fsConstants.X_OK);
  } catch {
    return false;
  }
  const result = spawnSync(path, ["--version"], { encoding: "utf8", timeout: 5000 });
  return result.status === 0;
}

function isGrokAgent(path) {
  const result = spawnSync(path, ["--version"], { encoding: "utf8", timeout: 5000 });
  const out = `${result.stdout ?? ""}${result.stderr ?? ""}`.toLowerCase();
  return out.includes("grok");
}

function resolveProbeCommand(command) {
  const hostHome = process.env.GEGENLESEN_HOST_HOME?.trim();
  if (!hostHome) return command;

  const head = String(command[0] ?? "");
  const wantsCursor = command[1] === "acp";
  const wantsGrok = command.includes("stdio");

  if (wantsCursor || (head.endsWith("/agent") && !wantsGrok && command[1] === "acp")) {
    const cursorAgent = process.env.GEGENLESEN_CURSOR_AGENT?.trim();
    if (cursorAgent && isRunnable(cursorAgent) && !isGrokAgent(cursorAgent)) {
      return [cursorAgent, "acp"];
    }
    for (const candidate of ["/usr/local/bin/cursor-agent"]) {
      if (candidate && isRunnable(candidate) && !isGrokAgent(candidate)) {
        return [candidate, "acp"];
      }
    }
  }

  if (wantsGrok || (head.includes("grok") && command.includes("stdio")) || isGrokAgent(head)) {
    const grokAgent = process.env.GEGENLESEN_GROK_AGENT?.trim();
    if (grokAgent && isRunnable(grokAgent) && isGrokAgent(grokAgent)) {
      return [grokAgent, "agent", "stdio"];
    }
    for (const candidate of ["/usr/local/bin/grok"]) {
      if (candidate && isRunnable(candidate) && isGrokAgent(candidate)) {
        return [candidate, "agent", "stdio"];
      }
    }
  }

  if (head === "agent" && command[1] === "acp") {
    const cursorAgent = process.env.GEGENLESEN_CURSOR_AGENT?.trim();
    if (cursorAgent && isRunnable(cursorAgent) && !isGrokAgent(cursorAgent)) {
      return [cursorAgent, "acp"];
    }
    for (const candidate of ["/usr/local/bin/cursor-agent"]) {
      if (candidate && isRunnable(candidate) && !isGrokAgent(candidate)) {
        return [candidate, "acp"];
      }
    }
  }

  return command;
}

function applyHostHomeEnv() {
  const hostHome = process.env.GEGENLESEN_HOST_HOME?.trim();
  if (!hostHome) return;
  process.env.HOME = hostHome;
}

function grokProbeHome(hostHome) {
  const probeHome = mkdtempSync(join(tmpdir(), "gegenlesen-acp-probe-grok-"));
  const grokDir = join(probeHome, ".grok");
  mkdirSync(grokDir, { recursive: true });
  try {
    cpSync(join(hostHome, ".grok", "auth.json"), join(grokDir, "auth.json"));
  } catch {}
  process.env.HOME = probeHome;
}

function codexProbeHome(hostHome) {
  const probeHome = mkdtempSync(join(tmpdir(), "gegenlesen-acp-probe-codex-"));
  const codexDir = join(probeHome, ".codex");
  mkdirSync(codexDir, { recursive: true });
  try {
    cpSync(join(hostHome, ".codex", "auth.json"), join(codexDir, "auth.json"));
  } catch {}
  process.env.HOME = probeHome;
}

function cursorProbeHome(hostHome) {
  const probeHome = mkdtempSync(join(tmpdir(), "gegenlesen-acp-probe-cursor-"));
  const cursorDir = join(probeHome, ".cursor");
  mkdirSync(cursorDir, { recursive: true });
  for (const name of ["cli-config.json", "acp-config.json"]) {
    try {
      cpSync(join(hostHome, ".cursor", name), join(cursorDir, name));
    } catch {}
  }
  try {
    cpSync(join(hostHome, ".cursor", "sdk"), join(cursorDir, "sdk"), { recursive: true });
  } catch {}
  process.env.HOME = probeHome;
}

function parseArgs(argv) {
  const idx = argv.indexOf("--");
  if (idx < 0 || idx === argv.length - 1) {
    throw new Error("usage: acp-models.mjs -- command [args...]");
  }
  return argv.slice(idx + 1);
}

function extractModels(session) {
  const out = [];
  const seen = new Set();

  function push(id, name, description) {
    const trimmed = String(id ?? "").trim();
    if (!trimmed || seen.has(trimmed)) return;
    seen.add(trimmed);
    out.push({
      id: trimmed,
      name: String(name ?? trimmed).trim() || trimmed,
      description: description ? String(description).trim() : undefined,
    });
  }

  const available = session?.models?.availableModels;
  if (Array.isArray(available)) {
    for (const entry of available) {
      push(entry.modelId ?? entry.id, entry.name, entry.description);
    }
  }

  const options = session?.configOptions;
  if (Array.isArray(options)) {
    for (const option of options) {
      if (option.category !== "model" && option.id !== "model") continue;
      for (const choice of option.options ?? []) {
        push(choice.value ?? choice.modelId, choice.name, choice.description);
      }
    }
  }

  return out;
}

async function probe(command) {
  const child = spawn(command[0], command.slice(1), {
    stdio: ["pipe", "pipe", "pipe"],
    env: process.env,
    detached: process.platform !== "win32",
  });

  function killTree() {
    if (!child.pid) return;
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {
      try {
        child.kill("SIGKILL");
      } catch {}
    }
  }

  let buffer = "";
  let nextId = 0;
  const pending = new Map();
  let spawnError = null;

  child.on("error", (err) => {
    spawnError = err;
    for (const { reject } of pending.values()) {
      reject(err);
    }
    pending.clear();
  });

  child.stdout.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        continue;
      }
      if (message.id != null && pending.has(message.id)) {
        const { resolve, reject } = pending.get(message.id);
        pending.delete(message.id);
        if (message.error) reject(new Error(JSON.stringify(message.error)));
        else resolve(message.result);
      }
    }
  });

  child.stderr.on("data", () => {});

  child.stdin.on("error", (err) => {
    for (const { reject } of pending.values()) {
      reject(err);
    }
    pending.clear();
  });

  child.on("exit", () => {
    for (const { reject } of pending.values()) {
      reject(new Error("ACP agent exited before responding"));
    }
    pending.clear();
  });

  function request(method, params) {
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      const payload = `${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`;
      const ok = child.stdin.write(payload, (err) => {
        if (err) reject(err);
      });
      if (!ok && spawnError) reject(spawnError);
      setTimeout(() => {
        if (!pending.has(id)) return;
        pending.delete(id);
        reject(new Error(`timeout waiting for ${method}`));
      }, 20_000);
    });
  }

  try {
    if (spawnError) throw spawnError;
    await request("initialize", {
      protocolVersion: 1,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
    });
    const session = await request("session/new", {
      cwd: process.env.HOME || process.cwd(),
      mcpServers: [],
    });
    return extractModels(session);
  } finally {
    killTree();
  }
}

const command = resolveProbeCommand(parseArgs(process.argv));
const hostHome = process.env.GEGENLESEN_HOST_HOME?.trim();
if (hostHome) {
  if (command.some((part) => String(part).includes("codex-acp"))) {
    codexProbeHome(hostHome);
  } else if (command[1] === "acp") {
    cursorProbeHome(hostHome);
  } else if (command.includes("stdio")) {
    grokProbeHome(hostHome);
  } else {
    applyHostHomeEnv();
  }
} else {
  applyHostHomeEnv();
}
const models = await probe(command);
process.stdout.write(`${JSON.stringify({ models, source: "acp" })}\n`);
