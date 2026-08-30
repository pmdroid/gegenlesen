const SEVERITIES = new Set(["info", "warning", "error"]);
const JUDGE_VERDICTS = new Set(["keep", "drop", "downgrade"]);

const FINDINGS_STRING_LIMITS = {
  title: 200,
  message: 4000,
  file_path: 4096,
  snippet: 4096,
};

const JUDGE_STRING_LIMITS = {
  finding_id: Infinity,
  rationale: 4000,
};

function push(errors, path, message) {
  errors.push({ path, message });
}

function requireNonEmptyString(errors, base, key, value, maxLength = Infinity) {
  if (value === undefined || value === null || value === "") {
    push(errors, `${base}.${key}`, "required");
    return;
  }
  if (typeof value !== "string") {
    push(errors, `${base}.${key}`, "expected string");
    return;
  }
  if (value.length < 1) {
    push(errors, `${base}.${key}`, "minLength 1");
  }
  if (value.length > maxLength) {
    push(errors, `${base}.${key}`, `maxLength ${maxLength}`);
  }
}

function requirePositiveInteger(errors, base, key, value) {
  if (value === undefined || value === null || value === "") {
    push(errors, `${base}.${key}`, "required");
    return;
  }
  if (!Number.isInteger(value)) {
    push(errors, `${base}.${key}`, "expected integer");
    return;
  }
  if (value < 1) {
    push(errors, `${base}.${key}`, "minimum 1");
  }
}

function rejectExtraKeys(errors, base, obj, allowed) {
  for (const key of Object.keys(obj)) {
    if (!allowed.has(key)) {
      push(errors, `${base}.${key}`, "additional property not allowed");
    }
  }
}

export function validateFindingsDocument(parsed) {
  const errors = [];
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    push(errors, "$", "expected object");
    return errors;
  }
  rejectExtraKeys(errors, "$", parsed, new Set(["findings"]));
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
    for (const [key, maxLength] of Object.entries(FINDINGS_STRING_LIMITS)) {
      requireNonEmptyString(errors, base, key, finding[key], maxLength);
    }
    requirePositiveInteger(errors, base, "start_line", finding.start_line);
    requirePositiveInteger(errors, base, "end_line", finding.end_line);
    if (finding.severity === undefined || finding.severity === null || finding.severity === "") {
      push(errors, `${base}.severity`, "required");
    } else if (!SEVERITIES.has(finding.severity)) {
      push(errors, `${base}.severity`, "invalid enum");
    }
    if (
      Number.isInteger(finding.start_line) &&
      Number.isInteger(finding.end_line) &&
      finding.end_line < finding.start_line
    ) {
      push(errors, `${base}.end_line`, "must be >= start_line");
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
  rejectExtraKeys(errors, "$", parsed, new Set(["verdicts"]));
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
    rejectExtraKeys(errors, base, row, new Set(["finding_id", "verdict", "severity", "rationale"]));
    requireNonEmptyString(errors, base, "finding_id", row.finding_id, JUDGE_STRING_LIMITS.finding_id);
    requireNonEmptyString(errors, base, "rationale", row.rationale, JUDGE_STRING_LIMITS.rationale);
    if (row.verdict === undefined || row.verdict === null || row.verdict === "") {
      push(errors, `${base}.verdict`, "required");
    } else if (!JUDGE_VERDICTS.has(row.verdict)) {
      push(errors, `${base}.verdict`, "invalid enum");
    }
    if (row.severity !== undefined && row.severity !== null && row.severity !== "" && !SEVERITIES.has(row.severity)) {
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
