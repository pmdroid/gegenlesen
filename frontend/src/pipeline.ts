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
      return "judge";
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

export function isArchiveTitle(title: string | null | undefined): boolean {
  if (!title) return true;
  return /\.(tar\.gz|tgz)$/i.test(title);
}

export function githubRepoParts(
  repository: string | null | undefined,
): { owner: string; repo: string } | null {
  if (!repository) return null;
  const cleaned = repository.replace(/\.git$/i, "");
  const match = cleaned.match(/(?:github\.com[/:]|git@github\.com:)([^/]+)\/([^/]+)$/i);
  if (!match) return null;
  return { owner: match[1], repo: match[2] };
}

export function shortRepo(repository: string | null | undefined): string | null {
  const github = githubRepoParts(repository);
  if (github) return `${github.owner}/${github.repo}`;
  if (!repository) return null;
  const parts = repository.split("/").filter(Boolean);
  return parts.length >= 2 ? parts.slice(-2).join("/") : repository;
}

export function abbrevSHA(sha: string | null | undefined): string | null {
  if (!sha) return null;
  return sha.slice(0, 7);
}

export function displayJobTitle(job: JobListItem, prNumber?: number | null): string {
  if (!isArchiveTitle(job.title)) return job.title ?? job.id;
  const repo = shortRepo(job.repository);
  const hash = abbrevSHA(job.head_sha ?? job.base_sha);
  if (repo && prNumber != null) return `${repo}/${prNumber}`;
  if (repo && hash) return `${repo}/${hash}`;
  if (prNumber != null) return `${prNumber}`;
  return hash ?? repo ?? job.id;
}

export function pullMapKey(job: Pick<JobListItem, "repository" | "head_sha">): string | null {
  const github = githubRepoParts(job.repository);
  if (!github || !job.head_sha) return null;
  return `${github.owner}/${github.repo}@${job.head_sha}`;
}

export function githubPullUrl(job: JobListItem, prNumber?: number | null): string | null {
  const github = githubRepoParts(job.repository);
  if (github && prNumber != null) {
    return `https://github.com/${github.owner}/${github.repo}/pull/${prNumber}`;
  }
  if (github && job.head_sha) {
    return `https://github.com/${github.owner}/${github.repo}/commit/${job.head_sha}`;
  }
  return null;
}

export function findingCounts(job: JobListItem): string | null {
  const summary = job.summary;
  if (!summary) return null;
  const parts = [
    summary.new ? `${summary.new} new` : null,
    summary.still_open ? `${summary.still_open} still open` : null,
    summary.dropped ? `${summary.dropped} dropped` : null,
    summary.relocated ? `${summary.relocated} relocated` : null,
    summary.resolved ? `${summary.resolved} resolved` : null,
  ].filter(Boolean);
  return parts.length > 0 ? parts.join(" · ") : "0 findings";
}
