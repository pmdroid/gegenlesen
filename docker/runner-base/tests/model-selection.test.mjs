import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const runner = fileURLToPath(new URL("../acp-runner.mjs", import.meta.url));
const peer = `
import { createInterface } from "node:readline";
import { appendFileSync } from "node:fs";
const mode = process.env.TEST_MODE;
const input = createInterface({ input: process.stdin });
input.on("close", () => process.exit(0));
input.on("line", (line) => {
  const message = JSON.parse(line);
  appendFileSync(process.env.TEST_CALLS, message.method + "\\n");
  const send = (result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) + "\\n");
  const reject = () => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "unsupported" } }) + "\\n");
  if (message.method === "initialize") {
    if (mode === "hang") return;
    if (mode === "early-exit") process.exit(0);
    send({ protocolVersion: 1 });
  } else if (message.method === "session/new") {
    send({ sessionId: "test", configOptions: mode === "legacy" ? [] : [{ [mode === "compat" ? "configId" : "id"]: "model", category: "model", currentValue: "default" }] });
  } else if (message.method === "session/set_config_option") {
    if (mode === "rejected") reject();
    else send({ configOptions: [{ id: "model", category: "model", currentValue: mode === "mismatch" ? "wrong-model" : message.params.value }] });
  } else if (message.method === "session/set_model") {
    if (mode === "legacy") send({});
    else reject();
  } else if (message.method === "session/prompt") {
    if (mode === "slow-prompt") setTimeout(() => send({ stopReason: "end_turn" }), 150);
    else send({ stopReason: "end_turn" });
  }
});
`;

function run(mode) {
  const root = mkdtempSync(join(tmpdir(), "gegenlesen-model-"));
  const callsPath = join(root, "calls");
  try {
    writeFileSync(join(root, "peer.mjs"), peer);
    writeFileSync(callsPath, "");
    const started = performance.now();
    const result = spawnSync(process.execPath, [runner, "--timeout-sec", "2", "--setup-timeout-sec", "0.1", "--", process.execPath, join(root, "peer.mjs")], {
      encoding: "utf8",
      timeout: 4000,
      env: { ...process.env, GEGENLESEN_WORKSPACE: root, CODEX_ACP_MODEL: "requested-model", TEST_MODE: mode, TEST_CALLS: callsPath },
    });
    return { ...result, calls: readFileSync(callsPath, "utf8"), elapsed: performance.now() - started };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

for (const mode of ["v1", "compat", "legacy", "slow-prompt"]) {
  test(`model selection succeeds with ${mode}`, () => {
    const result = run(mode);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.calls, /session\/prompt/);
    assert.match(result.stderr, /model acknowledged: requested-model/);
    if (mode !== "legacy") assert.doesNotMatch(result.calls, /session\/set_model/);
  });
}

for (const mode of ["rejected", "mismatch", "early-exit"]) {
  test(`${mode} cannot start investigation`, () => {
    const result = run(mode);
    assert.notEqual(result.status, 0);
    assert.doesNotMatch(result.calls, /session\/prompt/);
  });
}

test("setup shares a short deadline", () => {
  const result = run("hang");
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /setup deadline/);
  assert.ok(result.elapsed < 1500, `elapsed ${result.elapsed}ms`);
});
