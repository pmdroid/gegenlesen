import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { validateFindingsDocument, validateJudgeDocument, validateOutput } from "../lib/validate.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = join(here, "fixtures");

function load(name) {
  return readFileSync(join(fixtures, name), "utf8");
}

assert.deepEqual(validateOutput("findings", load("findings-valid.json")), []);
assert.deepEqual(validateOutput("judge", load("judge-valid.json")), []);

const findingsInvalid = validateOutput("findings", load("findings-invalid.json"));
assert.ok(findingsInvalid.some((e) => e.path.includes("severity")));
assert.ok(findingsInvalid.some((e) => e.path.includes("start_line")));

const findingsStringLines = validateOutput("findings", load("findings-string-lines.json"));
assert.ok(findingsStringLines.some((e) => e.message.includes("integer")));

const judgeInvalid = validateOutput("judge", load("judge-invalid.json"));
assert.ok(judgeInvalid.some((e) => e.path.includes("verdict")));

const garbage = validateOutput("findings", load("findings-garbage.txt"));
assert.equal(garbage.length, 1);
assert.match(garbage[0].message, /invalid json/i);

assert.deepEqual(validateFindingsDocument(null), [{ path: "$", message: "expected object" }]);
assert.deepEqual(validateJudgeDocument({ verdicts: "nope" }), [{ path: "$.verdicts", message: "required array" }]);

console.log("validate.test.mjs: ok");
