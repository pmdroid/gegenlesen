import type {
  FindingFeedback,
  FindingFeedbackRequest,
  ContextNote,
  ContextNoteUpsert,
  HealthDTO,
  JobDetail,
  JobListResponse,
  Learning,
  MineAccepted,
  LearningKind,
  LearningListResponse,
  LearningStatus,
  Rule,
  RuleListResponse,
  RuleUpsert,
  SettingsDTO,
  TranscriptPhase,
} from "./api";

export class HTTPError extends Error {
  readonly status: number;

  constructor(path: string, status: number) {
    super(`${path} ${status}`);
    this.name = "HTTPError";
    this.status = status;
  }
}

export function isNotFound(error: unknown): boolean {
  return error instanceof HTTPError && error.status === 404;
}

async function getJSON<T>(path: string): Promise<T> {
  const res = await fetch(path);
  if (!res.ok) {
    throw new HTTPError(path, res.status);
  }
  return res.json() as Promise<T>;
}

async function getText(path: string): Promise<string> {
  const res = await fetch(path);
  if (!res.ok) {
    throw new HTTPError(path, res.status);
  }
  return res.text();
}

async function sendJSON<T>(path: string, method: string, body?: unknown): Promise<T> {
  const res = await fetch(path, {
    method,
    headers: body === undefined ? undefined : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) {
    throw new HTTPError(path, res.status);
  }
  if (res.status === 204) {
    return undefined as T;
  }
  return res.json() as Promise<T>;
}

export function getHealth(): Promise<HealthDTO> {
  return getJSON("/api/health");
}

export function getSettings(): Promise<SettingsDTO> {
  return getJSON("/api/settings");
}

export function listJobs(): Promise<JobListResponse> {
  return getJSON("/api/jobs");
}

export function getJob(id: string): Promise<JobDetail> {
  return getJSON(`/api/jobs/${id}`);
}

export function getJobFeedback(id: string): Promise<{ feedback: FindingFeedback[] }> {
  return getJSON(`/api/jobs/${id}/feedback`);
}

export function getJobTranscript(id: string, phase: TranscriptPhase): Promise<string> {
  return getText(`/api/jobs/${id}/transcript?phase=${phase}`);
}

export function postFindingFeedback(
  id: string,
  body: FindingFeedbackRequest,
): Promise<FindingFeedback | undefined> {
  return sendJSON(`/api/findings/${id}/feedback`, "POST", body);
}

export function learnFromJob(id: string): Promise<MineAccepted> {
  return sendJSON(`/api/jobs/${id}/learn`, "POST");
}

export async function listInboxRules(): Promise<Rule[]> {
  const [suggested, mined, handwritten] = await Promise.all([
    listRules({ provenance: "suggested" }),
    listRules({ provenance: "mined" }),
    listRules({ provenance: "handwritten" }),
  ]);
  const promoted = new Set(
    handwritten.rules
      .map((rule) => rule.promoted_from_rule_id)
      .filter((id): id is string => Boolean(id)),
  );
  return [...suggested.rules, ...mined.rules].filter((rule) => !promoted.has(rule.id));
}

export function listRules(query?: {
  enabled?: boolean;
  kind?: string;
  provenance?: string;
}): Promise<RuleListResponse> {
  const params = new URLSearchParams();
  if (query?.enabled !== undefined) params.set("enabled", String(query.enabled));
  if (query?.kind) params.set("kind", query.kind);
  if (query?.provenance) params.set("provenance", query.provenance);
  const suffix = params.size ? `?${params.toString()}` : "";
  return getJSON(`/api/rules${suffix}`);
}

export function getRule(id: string): Promise<Rule> {
  return getJSON(`/api/rules/${id}`);
}

export function createRule(body: RuleUpsert): Promise<Rule> {
  return sendJSON("/api/rules", "POST", body);
}

export function updateRule(id: string, body: RuleUpsert): Promise<Rule> {
  return sendJSON(`/api/rules/${id}`, "PUT", body);
}

export function deleteRule(id: string): Promise<Rule> {
  return sendJSON(`/api/rules/${id}`, "DELETE");
}

export function promoteRule(id: string): Promise<Rule> {
  return sendJSON(`/api/rules/${id}/promote`, "POST");
}

export function enableRule(id: string): Promise<Rule> {
  return sendJSON(`/api/rules/${id}/enable`, "POST");
}

export function disableRule(id: string): Promise<Rule> {
  return sendJSON(`/api/rules/${id}/disable`, "POST");
}

export function listContextNotes(): Promise<{ notes: ContextNote[] }> {
  return getJSON("/api/context");
}

export function createContextNote(body: ContextNoteUpsert): Promise<ContextNote> {
  return sendJSON("/api/context", "POST", body);
}

export function updateContextNote(id: string, body: ContextNoteUpsert): Promise<ContextNote> {
  return sendJSON(`/api/context/${id}`, "PUT", body);
}

export function deleteContextNote(id: string): Promise<ContextNote> {
  return sendJSON(`/api/context/${id}`, "DELETE");
}

export function listLearnings(query?: {
  status?: LearningStatus;
  kind?: LearningKind;
}): Promise<LearningListResponse> {
  const params = new URLSearchParams();
  if (query?.status) params.set("status", query.status);
  if (query?.kind) params.set("kind", query.kind);
  const suffix = params.size ? `?${params.toString()}` : "";
  return getJSON(`/api/learnings${suffix}`);
}

export function acceptLearning(id: string): Promise<Learning> {
  return sendJSON(`/api/learnings/${id}/accept`, "POST");
}

export function dismissLearning(id: string): Promise<Learning> {
  return sendJSON(`/api/learnings/${id}/dismiss`, "POST");
}
