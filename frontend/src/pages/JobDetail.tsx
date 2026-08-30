import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Link, useParams } from "react-router-dom";
import { FindingsTable } from "../components/FindingsTable";
import { PipelineRail } from "../components/PipelineRail";
import { reviewSlots, SlotBadges } from "../components/SlotBadges";
import { TranscriptViewer } from "../components/TranscriptViewer";
import { isTerminal, type FindingFeedbackRequest } from "../api";
import { getJob, getJobFeedback, isNotFound, learnFromJob, postFindingFeedback, postRiskLabel } from "../client";
import { usePullNumbers } from "../github";
import { displayJobTitle, githubPullUrl, jobDuration, pullMapKey, shortSHA, statusClass } from "../pipeline";
import { repoLabel } from "../scope";

export function JobDetailPage() {
  const { id } = useParams();
  const queryClient = useQueryClient();
  const [showDropped, setShowDropped] = useState(false);
  const job = useQuery({
    queryKey: ["job", id],
    queryFn: () => getJob(id ?? ""),
    enabled: Boolean(id),
    refetchInterval: (query) => {
      const status = query.state.data?.status;
      return status && !isTerminal(status) ? 2000 : false;
    },
    retry: false,
  });
  const feedback = useQuery({
    queryKey: ["job", id, "feedback"],
    queryFn: () => getJobFeedback(id ?? ""),
    enabled: Boolean(id) && job.isSuccess,
    refetchInterval: job.data && !isTerminal(job.data.status) ? 2000 : false,
    retry: false,
  });
  const send = useMutation({
    mutationFn: ({ findingId, body }: { findingId: string; body: FindingFeedbackRequest }) =>
      postFindingFeedback(findingId, body),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["job", id, "feedback"] });
      void queryClient.invalidateQueries({ queryKey: ["rules"] });
    },
  });
  const learn = useMutation({
    mutationFn: () => learnFromJob(id ?? ""),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["jobs"] });
      void queryClient.invalidateQueries({ queryKey: ["learnings"] });
    },
  });
  const riskLabel = useMutation({
    mutationFn: (safeUnread: boolean) => postRiskLabel(id ?? "", safeUnread),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["job", id] });
      void queryClient.invalidateQueries({ queryKey: ["jobs"] });
    },
  });
  const pulls = usePullNumbers(job.data ? [job.data] : []);

  if (!id) {
    return (
      <div className="page">
        <div className="empty">Missing job id.</div>
      </div>
    );
  }

  if (job.isError) {
    return (
      <div className="page">
        <Link to="/">← jobs</Link>
        <div className="empty">Job not found or the API is down.</div>
      </div>
    );
  }

  if (!job.data) {
    return (
      <div className="page">
        <div className="logline">loading {id}…</div>
      </div>
    );
  }

  const detail = job.data;
  const live = !isTerminal(detail.status);
  const canLearn =
    isTerminal(detail.status) &&
    detail.status !== "cancelled" &&
    !(detail.title ?? "").startsWith("learn ");
  const events = detail.events.slice(-40);
  const droppedCount = detail.findings.filter((finding) => finding.judge_verdict === "drop").length;
  const visibleFindings = showDropped
    ? detail.findings
    : detail.findings.filter((finding) => finding.judge_verdict !== "drop");
  const duration = jobDuration(detail);
  const prKey = pullMapKey(detail);
  const prNumber = prKey ? pulls[prKey] : null;
  const title = displayJobTitle(detail, prNumber);
  const pullUrl = githubPullUrl(detail, prNumber);
  const askMerge = detail.status === "succeeded" && detail.risk != null && detail.risk.safe_unread == null;

  return (
    <div className="page">
      <div className="pagehead">
        <h1>
          {pullUrl ? (
            <a href={pullUrl} target="_blank" rel="noreferrer">
              {title}
            </a>
          ) : (
            title
          )}
        </h1>
        <span className={statusClass(detail.status)}>{detail.status}</span>
        {detail.risk ? (
          <span className={detail.risk.verdict === "auto_approve" ? "st ok" : "st human"}>
            {detail.risk.verdict}
          </span>
        ) : null}
        <Link to="/">← jobs</Link>
      </div>
      {detail.status !== "failed" && detail.status !== "cancelled" ? (
        <PipelineRail status={detail.status} />
      ) : null}
      <SlotBadges slots={reviewSlots(detail)} />
      <div className="pipe">
        {detail.error_message ? `${detail.error_message} · ` : "det → A ∥ B → judge · "}
        {duration ?? "—"}
        {detail.repository ? ` · ${repoLabel(detail.repository)}` : ""}
        {` · ${shortSHA(detail.head_sha ?? detail.base_sha)}`}
        {detail.parent_job_id ? (
          <>
            {" · "}
            <Link to={`/jobs/${detail.parent_job_id}`}>parent {detail.parent_job_id.slice(0, 8)}</Link>
          </>
        ) : null}
      </div>

      <div className="pagehead">
        <h2>findings</h2>
        <label className="toggle">
          <input type="checkbox" checked={showDropped} onChange={(event) => setShowDropped(event.target.checked)} />
          show dropped{droppedCount > 0 ? ` (${droppedCount})` : ""}
        </label>
        {canLearn ? (
          <button type="button" className="btn" disabled={learn.isPending} onClick={() => learn.mutate()}>
            {learn.isPending ? "learning…" : "learn"}
          </button>
        ) : null}
      </div>
      {learn.isSuccess ? (
        <div className="logline">
          learn queued · <Link to={`/jobs/${learn.data.job_id}`}>{learn.data.job_id.slice(0, 8)}</Link>
        </div>
      ) : null}
      {learn.isError ? <div className="formerr">could not start learn</div> : null}
      <FindingsTable
        findings={visibleFindings}
        emptyLabel={
          detail.error_message === "provider_auth"
            ? "Review stopped before the second reviewer. Provider rejected the API key."
            : detail.findings.length === 0
              ? "No findings yet."
              : "No kept findings. Toggle show dropped to inspect judge drops."
        }
        feedback={feedback.data?.feedback ?? []}
        pending={send.isPending}
        onFeedback={(findingId, body) => send.mutate({ findingId, body })}
      />
      {feedback.isError && !isNotFound(feedback.error) ? <div className="formerr">could not load feedback</div> : null}
      {send.isError ? <div className="formerr">could not save feedback</div> : null}

      {askMerge ? (
        <div className="jobblock">
          <div className="pipe" style={{ borderBottom: 0 }}>
            would you have merged this unread?{" "}
            <button type="button" className="btn" disabled={riskLabel.isPending} onClick={() => riskLabel.mutate(true)}>
              yes
            </button>{" "}
            <button type="button" className="btn" disabled={riskLabel.isPending} onClick={() => riskLabel.mutate(false)}>
              no
            </button>
            <span className="sha"> writes risk.safe_unread · never pushes</span>
          </div>
          {riskLabel.isError ? <div className="formerr">could not save risk label</div> : null}
        </div>
      ) : detail.risk?.safe_unread != null ? (
        <div className="logline">
          {detail.risk.safe_unread ? "labeled would merge unread" : "labeled would not merge unread"}
        </div>
      ) : null}

      <details className="jobblock">
        <summary className="pipe">log ({events.length})</summary>
        {events.length === 0 ? (
          <div className="pipe" style={{ borderBottom: 0 }}>
            no events yet
          </div>
        ) : (
          events.map((event) => (
            <div className="logline" key={event.id}>
              {event.ts} · {event.level} · {event.message}
            </div>
          ))
        )}
      </details>
      <details className="jobblock">
        <summary className="pipe">transcripts</summary>
        <TranscriptViewer jobId={detail.id} live={live} title={detail.title} />
      </details>
    </div>
  );
}
