import { useQuery } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { isTerminal, type JobListItem, type JobStatus } from "../api";
import { listJobs, listLearnings, listRepositories } from "../client";
import { PipelineRail } from "../components/PipelineRail";
import { reviewSlots, SlotBadges } from "../components/SlotBadges";
import { usePullNumbers } from "../github";
import { displayJobTitle, findingCounts, pullMapKey, shortSHA, statusClass } from "../pipeline";

function statusChip(job: JobListItem): { className: string; label: string } {
  if (job.status === "failed" && job.error_message) {
    return { className: "st fail", label: job.error_message };
  }
  return { className: statusClass(job.status), label: job.status };
}

function jobLine(job: JobListItem): string {
  if (job.status === "failed") {
    return job.error_message ? `failed · ${job.error_message}` : "failed";
  }
  if (job.status === "cancelled") return "cancelled";
  const counts = findingCounts(job);
  if (job.status === "succeeded") {
    const unread =
      job.risk == null
        ? null
        : job.risk.safe_unread == null
          ? "merge-intent unanswered"
          : job.risk.safe_unread
            ? "would merge unread"
            : "would not merge unread";
    return [counts, unread].filter(Boolean).join(" · ");
  }
  switch (job.status) {
    case "queued":
      return "queued";
    case "unpacking":
    case "identifying":
    case "selecting_rules":
      return job.status.replace("_", " ");
    case "deterministic":
      return "det running";
    case "reviewing":
      return "A ∥ B running";
    case "judging":
      return "judge running";
  }
}

const STATUS_FILTERS = [
  { id: "all", label: "all" },
  { id: "active", label: "running" },
  { id: "queued", label: "queued" },
  { id: "succeeded", label: "succeeded" },
  { id: "failed", label: "failed" },
] as const;

export function JobsPage() {
  const [status, setStatus] = useState<(typeof STATUS_FILTERS)[number]["id"]>("all");
  const [repository, setRepository] = useState("all");
  const [q, setQ] = useState("");

  const repos = useQuery({
    queryKey: ["repositories"],
    queryFn: listRepositories,
    refetchInterval: 8000,
  });
  const inbox = useQuery({
    queryKey: ["learnings", "pending"],
    queryFn: () => listLearnings({ status: "pending" }),
    refetchInterval: 4000,
  });

  const jobsQuery = useMemo(() => {
    const query: Parameters<typeof listJobs>[0] = { limit: 200 };
    if (status === "active") query.active = true;
    else if (status !== "all") query.status = status as JobStatus;
    if (repository === "global") query.unscoped = true;
    else if (repository !== "all") query.repository = repository;
    if (q.trim()) query.q = q.trim();
    return query;
  }, [status, repository, q]);

  const jobs = useQuery({
    queryKey: ["jobs", jobsQuery],
    queryFn: () => listJobs(jobsQuery),
    refetchInterval: 2000,
  });

  const items = jobs.data?.jobs ?? [];
  const pulls = usePullNumbers(items);
  const queued = items.filter((job) => job.status === "queued").length;
  const running = items.filter((job) => !isTerminal(job.status) && job.status !== "queued").length;
  const pendingLearnings = inbox.data?.learnings?.length ?? 0;
  const repoNames = repos.data?.repositories ?? [];

  return (
    <div className="page">
      <div className="logline">
        queue {queued} · running {running}
        {pendingLearnings > 0 ? (
          <>
            {" · "}
            <Link to="/learnings">{pendingLearnings} learnings</Link>
          </>
        ) : null}
      </div>
      <div className="filters">
        {STATUS_FILTERS.map((item) => (
          <button
            key={item.id}
            type="button"
            className={status === item.id ? "chip on" : "chip"}
            onClick={() => setStatus(item.id)}
          >
            {item.label}
          </button>
        ))}
        <select value={repository} onChange={(event) => setRepository(event.target.value)}>
          <option value="all">all repos</option>
          <option value="global">unscoped</option>
          {repoNames.map((name) => (
            <option key={name} value={name}>
              {name}
            </option>
          ))}
        </select>
        <input value={q} onChange={(event) => setQ(event.target.value)} placeholder="filter title" aria-label="filter jobs" />
      </div>
      {items.length === 0 ? (
        <div className="empty">
          {status !== "all" || repository !== "all" || q.trim()
            ? "No jobs match this filter."
            : "No jobs yet. In a repo run `gegenlesen review`."}
        </div>
      ) : (
        items.map((job) => {
          const chip = statusChip(job);
          const key = pullMapKey(job);
          return (
            <div className="jobblock" key={job.id}>
              <div className="jobhead">
                <Link className="t" to={`/jobs/${job.id}`}>
                  {displayJobTitle(job, key ? pulls[key] : null)}
                </Link>
                <span className={chip.className}>{chip.label}</span>
                {job.status === "succeeded" && job.risk ? (
                  <span className={job.risk.verdict === "auto_approve" ? "st ok" : "st human"}>
                    {job.risk.verdict}
                  </span>
                ) : null}
              </div>
              {job.status !== "failed" && job.status !== "cancelled" ? <PipelineRail status={job.status} /> : null}
              <SlotBadges slots={reviewSlots(job)} compact />
              <div className="pipe" style={{ borderBottom: 0 }}>
                {jobLine(job)}
                {job.head_sha ? ` · ${shortSHA(job.head_sha)}` : ""}
              </div>
            </div>
          );
        })
      )}
    </div>
  );
}
