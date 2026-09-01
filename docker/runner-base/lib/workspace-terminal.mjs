import { spawn } from "node:child_process";
import { resolveUnderWorkspace } from "./workspace-fs.mjs";

function truncateOutput(text, byteLimit) {
  if (byteLimit === undefined || byteLimit === null) return { output: text, truncated: false };
  const buf = Buffer.from(text, "utf8");
  if (buf.length <= byteLimit) return { output: text, truncated: false };
  let start = buf.length - byteLimit;
  while (start < buf.length && (buf[start] & 0xc0) === 0x80) start += 1;
  return { output: buf.slice(start).toString("utf8"), truncated: true };
}

function needsShell(command, args) {
  if (!command || (args ?? []).length > 0) return false;
  return /[|;&<>]/.test(command) || /\s/.test(command);
}

function spawnCommand({ command, args = [], env, cwd }) {
  const childEnv = { ...process.env, ...env };
  const resolvedCwd = cwd ? resolveUnderWorkspace(cwd) : undefined;
  if (needsShell(command, args)) {
    return spawn("/bin/sh", ["-c", command], {
      cwd: resolvedCwd,
      env: childEnv,
      stdio: ["ignore", "pipe", "pipe"],
    });
  }
  return spawn(command, args, {
    cwd: resolvedCwd,
    env: childEnv,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

export class WorkspaceTerminalManager {
  #terminals = new Map();
  #nextId = 1;

  create({ command, args = [], env = [], cwd, outputByteLimit }) {
    const terminalId = `term_${this.#nextId++}`;
    const childEnv = {};
    for (const entry of env) {
      if (entry?.name) childEnv[entry.name] = entry.value ?? "";
    }
    const child = spawnCommand({ command, args, env: childEnv, cwd });
    const state = {
      child,
      output: "",
      exitStatus: null,
      outputByteLimit,
      waiters: [],
    };
    const append = (chunk) => {
      state.output += chunk.toString("utf8");
      const { output, truncated } = truncateOutput(state.output, outputByteLimit);
      state.output = output;
      state.truncated = truncated;
    };
    child.stdout.on("data", append);
    child.stderr.on("data", append);
    child.on("error", (error) => {
      append(`\n${error.message}\n`);
      state.exitStatus = { exitCode: 127, signal: null };
      for (const resolve of state.waiters) resolve(state.exitStatus);
      state.waiters.length = 0;
    });
    child.on("close", (exitCode, signal) => {
      if (state.exitStatus) return;
      state.exitStatus = { exitCode, signal };
      for (const resolve of state.waiters) resolve(state.exitStatus);
      state.waiters.length = 0;
    });
    this.#terminals.set(terminalId, state);
    return { terminalId };
  }

  output(terminalId) {
    const state = this.#require(terminalId);
    return {
      output: state.output,
      truncated: Boolean(state.truncated),
      exitStatus: state.exitStatus,
    };
  }

  waitForExit(terminalId) {
    const state = this.#require(terminalId);
    if (state.exitStatus) return Promise.resolve(state.exitStatus);
    return new Promise((resolve) => {
      state.waiters.push(resolve);
    });
  }

  kill(terminalId) {
    const state = this.#require(terminalId);
    try {
      state.child.kill("SIGTERM");
    } catch {}
    return {};
  }

  release(terminalId) {
    const state = this.#terminals.get(terminalId);
    if (!state) return {};
    if (!state.exitStatus) {
      try {
        state.child.kill("SIGKILL");
      } catch {}
    }
    this.#terminals.delete(terminalId);
    return {};
  }

  #require(terminalId) {
    const state = this.#terminals.get(terminalId);
    if (!state) throw new Error(`unknown terminal: ${terminalId}`);
    return state;
  }
}
