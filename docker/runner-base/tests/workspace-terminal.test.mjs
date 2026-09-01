import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = mkdtempSync(join(tmpdir(), "gegenlesen-term-"));
process.env.GEGENLESEN_WORKSPACE = root;

const { WorkspaceTerminalManager } = await import("../lib/workspace-terminal.mjs");

const terminals = new WorkspaceTerminalManager();
const { terminalId } = terminals.create({
  command: "echo hello-from-shell",
});
const exitStatus = await terminals.waitForExit(terminalId);
const { output } = terminals.output(terminalId);

assert.equal(exitStatus.exitCode, 0);
assert.match(output, /hello-from-shell/);

const pipeline = terminals.create({
  command: "printf 'pipe-ok\\n'",
});
const pipelineExit = await terminals.waitForExit(pipeline.terminalId);
assert.equal(pipelineExit.exitCode, 0);

rmSync(root, { recursive: true, force: true });
console.log("workspace-terminal.test.mjs: ok");
