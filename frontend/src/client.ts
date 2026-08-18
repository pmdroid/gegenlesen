import type {
  HealthDTO,
  JobListResponse,
  Rule,
  RuleListResponse,
  RuleUpsert,
  SettingsDTO,
} from "./api";

async function getJSON<T>(path: string): Promise<T> {
  const res = await fetch(path);
  if (!res.ok) {
    throw new Error(`${path} ${res.status}`);
  }
  return res.json() as Promise<T>;
}

async function sendJSON<T>(path: string, method: string, body?: unknown): Promise<T> {
  const res = await fetch(path, {
    method,
    headers: body === undefined ? undefined : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(`${path} ${res.status}`);
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
