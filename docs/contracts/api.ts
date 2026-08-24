/**
 * gegenlesen HTTP + file-contract types.
 * Wire format is snake_case — these types match JSON 1:1.
 * Copy into frontend/src/ during PR 1. Keep in sync with
 * docs/technical-plan.md and schemas/openapi.yaml.
 */

export type JobId = string; // uuid v4
export type FindingId = string; // `fnd_` + ulid
export type RuleId = string; // kebab-case

export type JobStatus =
  | "queued"
  | "unpacking"
  | "identifying"
  | "selecting_rules"
  | "deterministic"
  | "reviewing"
  | "judging"
  | "succeeded"
  | "failed"
  | "cancelled";

export type JobScope = "full" | "incremental";
export type ReviewerSlot = "model_a" | "model_b";
export type Severity = "info" | "warning" | "error";
export type FindingPhase = "deterministic" | "agent";
export type JudgeVerdict = "keep" | "drop" | "downgrade" | "unavailable";
export type FindingLifecycle = "new" | "still_open" | "resolved" | "relocated";
export type RuleKind = "deterministic" | "semantic";
export type RuleProvenance = "handwritten" | "mined" | "suggested";
export type FileChangeStatus = "added" | "modified" | "deleted" | "renamed";
export type EventLevel = "debug" | "info" | "warning" | "error";
export type TranscriptPhase = "review" | "review_a" | "review_b" | "judge";
export type Language =
  | "swift"
  | "typescript"
  | "javascript"
  | "python"
  | "go"
  | "rust"
  | "jvm"
  | "c"
  | "ruby"
  | "csharp"
  | "shell"
  | "yaml"
  | "json"
  | "markdown"
  | "other";

export type ErrorCode =
  | "bad_request"
  | "not_found"
  | "forbidden"
  | "conflict"
  | "payload_too_large"
  | "unsupported_media_type"
  | "unprocessable"
  | "insufficient_storage"
  | "internal";

export function isTerminal(status: JobStatus): boolean {
  return status === "succeeded" || status === "failed" || status === "cancelled";
}

export interface APIErrorBody {
  error: {
    code: ErrorCode;
    message: string;
    details?: Record<string, string>;
  };
}

export interface HealthDTO {
  ok: true;
  version: string;
}

export interface Limits {
  archive_bytes: number;
  queued_archive_bytes: number;
  agent_timeout_sec: number;
  judge_timeout_sec: number;
  deterministic_timeout_sec: number;
  identify_timeout_sec: number;
  rule_token_budget: number;
  learn_interval_minutes: number;
  scanner_timeout_sec?: number;
}

export interface ModelSlots {
  model_a: string;
  model_b: string;
}

export type RiskMode = "off" | "shadow" | "enforce";
export type RiskVerdict = "auto_approve" | "needs_human";

export interface RiskConfig {
  mode: RiskMode;
  appetite: number;
  max_files: number;
  max_lines: number;
  sensitive_globs: string[];
}

export interface RiskReason {
  code: string;
  detail: string;
  finding_id: FindingId | null;
  points: number | null;
}

export interface RiskAssessment {
  verdict: RiskVerdict;
  mode: RiskMode;
  score: number;
  appetite: number;
  reasons: RiskReason[];
  safe_unread: boolean | null;
}

export interface SettingsDTO {
  bind: string;
  port: number;
  models: ModelSlots;
  judge_model: string;
  opencode_image: string;
  scanner_image?: string;
  limits: Limits;
  openrouter_configured: boolean;
  risk: RiskConfig;
}

export interface SettingsUpdate {
  models?: ModelSlots;
  judge_model?: string;
  openrouter_api_key?: string;
  scanner_image?: string;
  risk?: {
    mode?: RiskMode;
    appetite?: number;
  };
}

export interface OpenRouterModel {
  id: string;
  name: string;
  description?: string | null;
  context_length?: number | null;
  prompt_price?: string | null;
  free: boolean;
}

export interface OpenRouterModelList {
  models: OpenRouterModel[];
  total: number;
  query?: string | null;
  category?: string | null;
  sort?: string | null;
  free: boolean;
}

export interface CreateJobMeta {
  title?: string | null;
  scope: JobScope;
  reviewer_model?: ReviewerSlot | null; // ignored; both slots always run
  parent_job_id?: JobId | null;
  base_ref?: string | null;
  head_ref?: string | null;
  base_sha?: string | null;
  head_sha?: string | null;
}

export interface JobAccepted {
  id: JobId;
  status: "queued";
  queue_position: number;
}

export interface JobSummary {
  new: number;
  still_open: number;
  resolved: number;
  relocated: number;
  dropped: number;
}

export interface JobListItem {
  id: JobId;
  title: string | null;
  status: JobStatus;
  scope: JobScope;
  parent_job_id: JobId | null;
  repository: string | null;
  reviewer_a_model_id: string;
  reviewer_b_model_id: string;
  judge_model_id: string;
  base_sha: string | null;
  head_sha: string | null;
  queue_position: number | null;
  summary: JobSummary | null;
  created_at: string;
  started_at: string | null;
  finished_at: string | null;
  error_message: string | null;
  risk: RiskAssessment | null;
}

export interface JobEvent {
  id: number;
  job_id: JobId;
  ts: string;
  level: EventLevel;
  message: string;
  payload_json?: string | null;
}

export type FeedbackVerdict = "agree" | "disagree" | "comment" | "should_be_rule";
export type FeedbackReaction = "thumbs_up" | "thumbs_down";

export interface FindingFeedback {
  id: number;
  finding_id: FindingId;
  job_id: JobId;
  ts: string;
  verdict: FeedbackVerdict;
  reaction: FeedbackReaction | null;
  comment: string | null;
  suggested_rule_id: RuleId | null;
}

export interface FindingFeedbackRequest {
  verdict?: FeedbackVerdict;
  reaction?: FeedbackReaction | "👍" | "👎" | "+1" | "-1";
  comment?: string | null;
}

export interface Finding {
  id: FindingId;
  job_id: JobId;
  rule_id: RuleId | null;
  phase: FindingPhase;
  reviewer_slot: ReviewerSlot | null;
  severity: Severity;
  title: string;
  message: string;
  file_path: string | null;
  start_line: number | null;
  end_line: number | null;
  snippet: string | null;
  agent_rationale: string | null;
  judge_verdict: JudgeVerdict | null;
  judge_severity: Severity | null;
  judge_rationale: string | null;
  confidence: number | null;
  lifecycle: FindingLifecycle;
  parent_finding_id: FindingId | null;
  suggested_patch: string | null;
  evidence_ok: boolean | null;
  created_at: string;
  // fingerprint is SQL/matcher-only — never on this HTTP object
}

export interface JobDetail extends JobListItem {
  findings: Finding[];
  events: JobEvent[];
}

export interface JobListResponse {
  jobs: JobListItem[];
  total: number;
}

export type RulePayload =
  | { checker: "regex"; pattern: string; flags?: string; message: string }
  | { checker: "deny_api"; symbols: string[]; message: string }
  | { checker: "sibling_test"; source_glob: string; test_template: string }
  | { checker: "command"; argv: string[]; timeout_sec: number }
  | {
      checker: "openapi_break";
      spec_globs: string[];
      fail_on?: "breaking" | "changelog";
      message: string;
    }
  | {
      checker: "risk_weight";
      weight: number;
      match: "any" | "all";
      veto: boolean;
    }
  | { instruction: string; few_shots?: string[] };

export interface RuleExample {
  path?: string | null;
  excerpt: string;
  note?: string | null;
}

export interface Rule {
  id: RuleId;
  title: string;
  severity: Severity;
  kind: RuleKind;
  enabled: boolean;
  deleted_at: string | null;
  provenance: RuleProvenance;
  languages: string[];
  path_globs: string[];
  repository: string | null;
  payload: RulePayload;
  examples: RuleExample[];
  source_pr_refs: string[];
  promoted_from_rule_id: RuleId | null;
  body: string;
  created_at: string;
  updated_at: string;
}

export interface RuleUpsert {
  id?: RuleId;
  title: string;
  severity: Severity;
  kind: RuleKind;
  enabled?: boolean;
  languages: string[];
  path_globs: string[];
  repository?: string | null;
  payload: RulePayload;
  examples?: RuleExample[];
  body?: string;
}

export interface RuleListResponse {
  rules: Rule[];
}

export interface CorpusItem {
  id: string;
  source_label: string;
  title: string | null;
  body: string | null;
  comments_json: string | null;
  patch_relpath: string;
  mined_at: string | null;
  created_at: string;
}

export interface CorpusListResponse {
  items: CorpusItem[];
}

export interface CorpusAccepted {
  accepted: number;
}

export interface MineRequest {
  item_ids?: string[];
}

export interface MineAccepted {
  job_id: JobId;
}

export type ContextNoteKind = "user" | "architecture";
export type ChunkKind = "file" | "architecture" | "user" | "rule";
export type LearningKind = "rule" | "architecture" | "context";
export type LearningStatus = "pending" | "accepted" | "dismissed";
export type LearningDismissReason =
  | "duplicate"
  | "already_covered"
  | "too_specific"
  | "not_a_rule"
  | "other";

export interface ContextNote {
  id: string;
  kind: ContextNoteKind;
  title: string;
  body: string;
  path_globs: string[];
  always_include: boolean;
  repository: string | null;
  created_at: string;
  updated_at: string;
}

export interface ContextNoteUpsert {
  title: string;
  body: string;
  path_globs?: string[];
  always_include?: boolean;
  repository?: string | null;
}

export interface Learning {
  id: string;
  job_id: JobId | null;
  kind: LearningKind;
  status: LearningStatus;
  title: string;
  body: string;
  judged?: boolean | null;
  dismiss_reason?: LearningDismissReason | null;
  dismiss_comment?: string | null;
  created_at: string;
}

export interface LearningDismissRequest {
  reason?: LearningDismissReason;
  comment?: string;
}

export interface LearningListResponse {
  learnings: Learning[];
}

/** Agent-written `.gegenlesen/findings.json` */
export interface AgentFindingsFile {
  findings: AgentFinding[];
}

export interface AgentFinding {
  id?: string;
  rule_id?: string | null;
  severity: Severity;
  title: string;
  message: string;
  file_path: string;
  start_line: number;
  end_line: number;
  snippet: string;
  rationale?: string;
  confidence?: number;
  suggested_patch?: string | null;
}

/** Host-written `.gegenlesen/judge-input.json` */
export interface JudgeInputFile {
  candidates: JudgeCandidate[];
}

export interface JudgeCandidate {
  id: FindingId;
  rule_id?: RuleId | null;
  severity: Severity;
  title: string;
  message: string;
  file_path: string;
  start_line: number;
  end_line: number;
  snippet: string;
  rationale?: string;
  phase: FindingPhase;
  evidence_ok: boolean;
  actual_slice: string;
}

/** Judge-written `.gegenlesen/judge.json` */
export interface JudgeFile {
  verdicts: JudgeVerdictRow[];
}

export interface JudgeVerdictRow {
  finding_id: FindingId;
  verdict: "keep" | "drop" | "downgrade";
  rationale: string;
  severity?: Severity;
}

export interface WorkspaceFileEntry {
  path: string;
  status: FileChangeStatus;
  sha256: string | null;
  language: Language;
  old_path: string | null;
}
