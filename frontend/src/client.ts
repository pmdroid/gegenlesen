import type { HealthDTO, JobListResponse, SettingsDTO } from "./api";

async function getJSON<T>(path: string): Promise<T> {
  const res = await fetch(path);
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
