import { readFileSync } from "node:fs";
import { atomicWrite, judgeCandidateIDs, resultDigest, submissionErrors } from "./lib/submission.mjs";

const kind = process.env.GEGENLESEN_OUTPUT_KIND;
const outputPath = process.env.GEGENLESEN_OUTPUT_PATH;
const runID = process.env.GEGENLESEN_SUBMISSION_ID;
try {
  if (!runID || !outputPath || !["findings", "judge"].includes(kind)) {
    throw new Error("result submission is unavailable outside an active review or judge session");
  }
  const raw = readFileSync(0, "utf8");
  const errors = submissionErrors(kind, raw, judgeCandidateIDs(kind, outputPath));
  if (errors.length) {
    process.stdout.write(JSON.stringify({ accepted: false, errors }) + "\n");
    process.exitCode = 1;
  } else {
    atomicWrite(outputPath, raw);
    atomicWrite(`${outputPath}.submitted`, JSON.stringify({ run_id: runID, kind, output_path: outputPath, sha256: resultDigest(raw) }));
    process.stdout.write(JSON.stringify({ accepted: true }) + "\n");
  }
} catch (error) {
  process.stdout.write(JSON.stringify({ accepted: false, errors: [{ message: error.message }] }) + "\n");
  process.exitCode = 1;
}
