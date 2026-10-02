import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const runner = fileURLToPath(new URL("../acp-runner.mjs", import.meta.url));
const submit = fileURLToPath(new URL("../submit-result.mjs", import.meta.url));
const peer = `
import { createInterface } from "node:readline";
import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";
const input = createInterface({ input: process.stdin });
const mode = process.env.TEST_MODE;
input.on("close", () => {
  if (mode === "rewrite") writeFileSync(process.env.GEGENLESEN_OUTPUT_PATH, '{"findings":["late rewrite"]}');
  process.exit(0);
});
input.on("line", (line) => {
  const message = JSON.parse(line);
  const send = (result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) + "\\n");
  if (message.method === "initialize") send({ protocolVersion: 1 });
  else if (message.method === "session/new") send({ sessionId: "test" });
  else if (message.method === "session/prompt") {
    if (mode === "partial" || mode === "no-submit") {
      writeFileSync(process.env.TEST_OUTPUT, '{"findings":[]}');
      if (mode === "no-submit") send({ stopReason: "end_turn" });
      return;
    }
    const payload = process.env.TEST_KIND === "judge" ? '{"verdicts":[]}' : '{"findings":[]}';
    if (mode === "repair") {
      const invalid = spawnSync(process.execPath, [process.env.TEST_SUBMIT], { input: '{"findings":[{}]}', encoding: "utf8" });
      if (invalid.status === 0) process.exit(9);
    }
    const submitted = spawnSync(process.execPath, [process.env.TEST_SUBMIT], { input: payload, encoding: "utf8" });
    if (submitted.status !== 0) return;
    if (mode === "normal-end") send({ stopReason: "end_turn" });
  }
});
`;

function run(mode, kind = "findings") {
  const root = mkdtempSync(join(tmpdir(), "gegenlesen-submit-"));
  const outputPath = join(root, kind + ".json");
  try {
    writeFileSync(join(root, "peer.mjs"), peer);
    writeFileSync(join(root, "judge-input.json"), JSON.stringify({ candidates: [{ id: "candidate-1" }] }));
    const started = performance.now();
    const result = spawnSync(process.execPath, [runner, "--output", kind, "--output-path", outputPath, "--timeout-sec", "0.9", "--setup-timeout-sec", "0.3", "--", process.execPath, join(root, "peer.mjs")], {
      encoding: "utf8",
      timeout: 4000,
      env: { ...process.env, GEGENLESEN_WORKSPACE: root, CODEX_ACP_MODEL: "", ANTHROPIC_MODEL: "", CURSOR_ACP_MODEL: "", CURSOR_MODEL: "", GROK_ACP_MODEL: "", GROK_MODEL: "", TEST_MODE: mode, TEST_KIND: kind, TEST_OUTPUT: outputPath, TEST_SUBMIT: submit },
    });
    let output;
    try { output = readFileSync(outputPath, "utf8"); } catch {}
    return { ...result, output, elapsed: performance.now() - started };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

for (const mode of ["submit", "repair", "normal-end", "rewrite"]) {
  test(`explicit ${mode} completes without waiting for the model turn`, () => {
    const result = run(mode);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.output), { findings: [] });
    assert.match(result.stdout, /result_submitted/);
    assert.ok(result.elapsed < 850, `elapsed ${result.elapsed}ms`);
  });
}

for (const mode of ["partial", "no-submit"]) {
  test(`${mode} does not count as a completed review`, () => {
    const result = run(mode);
    assert.notEqual(result.status, 0);
    assert.deepEqual(JSON.parse(result.output), { findings: [] });
    assert.doesNotMatch(result.stdout, /result_submitted/);
  });
}

test("judge cannot submit while omitting a candidate", () => {
  const result = run("submit", "judge");
  assert.notEqual(result.status, 0);
  assert.doesNotMatch(result.stdout, /result_submitted/);
});
