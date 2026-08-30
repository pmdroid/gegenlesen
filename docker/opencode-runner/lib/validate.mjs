const SEVERITIES = new Set(["info", "warning", "error"]);
const JUDGE_VERDICTS = new Set(["keep", "drop", "downgrade"]);

function push(errors, path, message) {
  errors.push({ path, message });
}

export function validateFindingsDocument(parsed) {
  const errors = [];
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    push(errors, "$", "expected object");
    return errors;
  }
  if (!Array.isArray(parsed.findings)) {
    push(errors, "$.findings", "required array");
    return errors;
  }
  if (parsed.findings.length > 200) {
    push(errors, "$.findings", "too many findings (max 200)");
  }
  parsed.findings.forEach((finding, index) => {
    const base = `$.findings[${index}]`;
    if (!finding || typeof finding !== "object" || Array.isArray(finding)) {
      push(errors, base, "expected object");
      return;
    }
    for (const key of ["title", "message", "severity", "file_path", "start_line", "end_line", "snippet"]) {
      if (finding[key] === undefined || finding[key] === null || finding[key] === "") {
        push(errors, `${base}.${key}`, "required");
      }
    }
    if (finding.severity && !SEVERITIES.has(finding.severity)) {
      push(errors, `${base}.severity`, "invalid enum");
    }
    if (typeof finding.start_line === "number" && finding.start_line < 1) {
      push(errors, `${base}.start_line`, "minimum 1");
    }
    if (typeof finding.end_line === "number" && finding.end_line < 1) {
      push(errors, `${base}.end_line`, "minimum 1");
    }
  });
  return errors;
}

export function validateJudgeDocument(parsed) {
  const errors = [];
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    push(errors, "$", "expected object");
    return errors;
  }
  if (!Array.isArray(parsed.verdicts)) {
    push(errors, "$.verdicts", "required array");
    return errors;
  }
  if (parsed.verdicts.length > 200) {
    push(errors, "$.verdicts", "too many verdicts (max 200)");
  }
  parsed.verdicts.forEach((row, index) => {
    const base = `$.verdicts[${index}]`;
    if (!row || typeof row !== "object" || Array.isArray(row)) {
      push(errors, base, "expected object");
      return;
    }
    for (const key of ["finding_id", "verdict", "rationale"]) {
      if (row[key] === undefined || row[key] === null || row[key] === "") {
        push(errors, `${base}.${key}`, "required");
      }
    }
    if (row.verdict && !JUDGE_VERDICTS.has(row.verdict)) {
      push(errors, `${base}.verdict`, "invalid enum");
    }
    if (row.severity && !SEVERITIES.has(row.severity)) {
      push(errors, `${base}.severity`, "invalid enum");
    }
  });
  return errors;
}

export function validateOutput(kind, raw) {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    return [{ path: "$", message: `invalid json: ${error.message}` }];
  }
  return kind === "judge" ? validateJudgeDocument(parsed) : validateFindingsDocument(parsed);
}
