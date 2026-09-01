import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { mapSessionUpdate } from "../lib/transcript.mjs";
import { validateOutput } from "../lib/validate.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = join(here, "fixtures");

const goldenFindings = readFileSync(join(fixtures, "findings-valid.json"), "utf8");
assert.deepEqual(validateOutput("findings", goldenFindings), []);

const session = readFileSync(join(fixtures, "claude-acp-session.jsonl"), "utf8")
  .trim()
  .split("\n")
  .map((line) => JSON.parse(line));

for (const frame of session) {
  if (frame.method === "session/update") {
    const mapped = mapSessionUpdate(frame.params?.update);
    assert.ok(mapped);
  }
}

const runner = join(here, "..", "acp-runner.mjs");
const unknown = spawnSync(
  process.execPath,
  [runner, "--output", "not-a-kind", "--", "true"],
  { encoding: "utf8" },
);
assert.notEqual(unknown.status, 0);
assert.match(`${unknown.stderr}${unknown.stdout}`, /suggestion_judge/);

const modelsScript = join(here, "..", "acp-models.mjs");
const missingClaude = spawnSync(
  process.execPath,
  [modelsScript, "--", "claude-code-acp"],
  {
    encoding: "utf8",
    env: {
      ...process.env,
      PATH: "/usr/bin:/bin",
      GEGENLESEN_HOST_HOME: join(here, "fixtures"),
      GEGENLESEN_CLAUDE: "",
    },
  },
);
assert.notEqual(missingClaude.status, 0);
assert.match(`${missingClaude.stderr}${missingClaude.stdout}`, /claude CLI not found on PATH/);
assert.doesNotMatch(`${missingClaude.stderr}`, /ENOENT/);

console.log("acp-contract.test.mjs: ok");
