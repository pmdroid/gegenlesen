#!/usr/bin/env node
import { spawn } from "node:child_process";

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
  });

  let buffer = "";
  let nextId = 0;
  const pending = new Map();

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

  function request(method, params) {
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
      setTimeout(() => {
        if (!pending.has(id)) return;
        pending.delete(id);
        reject(new Error(`timeout waiting for ${method}`));
      }, 20_000);
    });
  }

  try {
    await request("initialize", {
      protocolVersion: 1,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
    });
    const session = await request("session/new", { cwd: process.cwd(), mcpServers: [] });
    return extractModels(session);
  } finally {
    child.kill("SIGTERM");
  }
}

const command = parseArgs(process.argv);
const models = await probe(command);
process.stdout.write(`${JSON.stringify({ models, source: "acp" })}\n`);
