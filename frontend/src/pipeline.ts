import type { JobListItem, JobStatus } from "./api";

export const PIPELINE_STEPS = ["pack", "identify", "det", "A ∥ B", "judge"] as const;
export type PipelineStep = (typeof PIPELINE_STEPS)[number];

export function activePipelineStep(status: JobStatus): PipelineStep {
  switch (status) {
    case "queued":
    case "unpacking":
      return "pack";
    case "identifying":
    case "selecting_rules":
      return "identify";
    case "deterministic":
      return "det";
    case "reviewing":
      return "A ∥ B";
    case "judging":
    case "succeeded":
    case "failed":
    case "cancelled":
      return "judge";
  }
}

export function jobDuration(job: Pick<JobListItem, "created_at" | "started_at" | "finished_at">): string | null {
  const start = job.started_at ?? job.created_at;
  if (!start) return null;
  const t0 = Date.parse(start);
  const t1 = job.finished_at ? Date.parse(job.finished_at) : Date.now();
  if (!Number.isFinite(t0) || !Number.isFinite(t1) || t1 < t0) return null;
  const seconds = Math.round((t1 - t0) / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  return `${minutes}m${String(rest).padStart(2, "0")}s`;
}

export function shortSHA(sha: string | null): string {
  if (!sha) return "—";
  if (sha.length <= 15) return sha;
  return `${sha.slice(0, 7)}..${sha.slice(-7)}`;
}

export function statusClass(status: JobStatus): string {
  if (status === "succeeded") return "st ok";
  if (status === "failed" || status === "cancelled") return "st fail";
  return "st run";
}

export function findingCounts(job: JobListItem): string | null {
  const summary = job.summary;
  if (!summary) return null;
  const parts = [
    summary.new ? `${summary.new} new` : null,
    summary.still_open ? `${summary.still_open} still open` : null,
    summary.dropped ? `${summary.dropped} dropped` : null,
    summary.resolved ? `${summary.resolved} resolved` : null,
  ].filter(Boolean);
  return parts.length > 0 ? parts.join(" · ") : "0 findings";
}
