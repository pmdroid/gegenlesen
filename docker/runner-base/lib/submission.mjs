import { createHash, randomUUID } from "node:crypto";
import { readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { validateOutput } from "./validate.mjs";

export function atomicWrite(path, contents) {
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, contents, { flag: "wx", mode: 0o600 });
    renameSync(temporary, path);
  } finally {
    rmSync(temporary, { force: true });
  }
}

export function submissionErrors(kind, raw, expectedIDs) {
  const errors = validateOutput(kind, raw);
  if (errors.length || kind !== "judge") return errors;
  const actual = new Set(JSON.parse(raw).verdicts.map((row) => row.finding_id));
  if (expectedIDs === null || actual.size !== expectedIDs.length || expectedIDs.some((id) => !actual.has(id))) {
    errors.push({ path: "$.verdicts", message: "return exactly one verdict for every supplied candidate ID" });
  }
  return errors;
}

export function judgeCandidateIDs(kind, outputPath) {
  if (kind !== "judge") return null;
  try {
    const input = JSON.parse(readFileSync(join(dirname(outputPath), "judge-input.json"), "utf8"));
    if (!Array.isArray(input.candidates)) return null;
    const ids = input.candidates.map((candidate) => candidate.id);
    if (ids.some((id) => typeof id !== "string" || !id.trim()) || new Set(ids).size !== ids.length) return null;
    return ids;
  } catch {
    return null;
  }
}

export function resultDigest(raw) {
  return createHash("sha256").update(raw).digest("hex");
}

export function readSubmission({ kind, outputPath, runID, expectedIDs }) {
  try {
    const receipt = JSON.parse(readFileSync(`${outputPath}.submitted`, "utf8"));
    if (receipt.run_id !== runID || receipt.kind !== kind || receipt.output_path !== outputPath) return null;
    const raw = readFileSync(outputPath, "utf8");
    if (receipt.sha256 !== resultDigest(raw) || submissionErrors(kind, raw, expectedIDs).length) return null;
    return raw;
  } catch {
    return null;
  }
}
