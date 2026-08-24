import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Link, useParams } from "react-router-dom";
import { FindingsTable } from "../components/FindingsTable";
import { TranscriptViewer } from "../components/TranscriptViewer";
import { isTerminal, type FindingFeedbackRequest, type JobListItem, type JobStatus } from "../api";
import { getJob, getJobFeedback, isNotFound, learnFromJob, postFindingFeedback, postRiskLabel } from "../client";

function shortSHA(sha: string | null): string {
  if (!sha) return "—";
  if (sha.length <= 15) return sha;
  return `${sha.slice(0, 7)}..${sha.slice(-7)}`;
}

function statusClass(status: JobStatus): string {
  if (status === "succeeded") return "st ok";
  if (status === "failed" || status === "cancelled") return "st fail";
  return "st run";
}

function summaryLine(job: JobListItem): string | null {
  const summary = job.summary;
  if (!summary) return null;
  return `${summary.new} new · ${summary.still_open} still_open · ${summary.resolved} resolved · ${summary.relocated} relocated · ${summary.dropped} dropped`;
}

function failureLine(errorMessage: string | null): string {
  if (errorMessage === "provider_auth") {
    return "failed · provider_auth · provider rejected the API key";
  }
  if (errorMessage === "no_findings_file" || errorMessage === "reviewer_no_findings_file") {
    return `failed · ${errorMessage}`;
  }
  return errorMessage ? `failed · ${errorMessage}` : "failed";
}

function pipelineLine(job: JobListItem): string {
  switch (job.status) {
    case "queued":
      return "queued · det → A ∥ B → judge";
    case "unpacking":
    case "identifying":
    case "selecting_rules":
      return `${job.status.replace("_", " ")} · det → A ∥ B → judge`;
    case "deterministic":
      return "det running → A ∥ B → judge";
    case "reviewing":
      return "det ✓ → A running ∥ B running → judge pending";
    case "judging":
      return "det ✓ → A ∥ B → judge running";
    case "succeeded":
      return "det → A ∥ B → judge";
    case "failed":
      return failureLine(job.error_message);
    case "cancelled":
      return "cancelled";
  }
}

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

  return (
    <div className="page">
      <div className="pagehead">
        <h1>{detail.title ?? detail.id}</h1>
        <div className="formrow" style={{ marginTop: 0 }}>
          {canLearn ? (
            <button
              type="button"
              className="btn"
              disabled={learn.isPending}
              onClick={() => learn.mutate()}
            >
              {learn.isPending ? "learning…" : "learn from this job"}
            </button>
          ) : null}
          <Link to="/">← jobs</Link>
        </div>
      </div>
      {learn.isSuccess ? (
        <div className="logline">
          learn queued ·{" "}
          <Link to={`/jobs/${learn.data.job_id}`}>{learn.data.job_id.slice(0, 8)}</Link>
          {" · "}
          <Link to="/learnings">learnings</Link>
        </div>
      ) : null}
      {learn.isError ? <div className="formerr">could not start learn</div> : null}
      <div className="jobblock">
        <div className="jobhead">
          <span className="t">{detail.title ?? detail.id}</span>
          <span className="sha">{shortSHA(detail.head_sha ?? detail.base_sha)}</span>
          <span className={statusClass(detail.status)}>{detail.status}</span>
          {detail.risk ? (
            <span className={detail.risk.verdict === "auto_approve" ? "st ok" : "st human"}>
              {detail.risk.verdict}
            </span>
          ) : null}
        </div>
        <div className="pipe">{pipelineLine(detail)}</div>
        <div className="pipe" style={{ borderBottom: summaryLine(detail) ? undefined : 0 }}>
          posted by CLI · scope: {detail.scope}
          {detail.repository ? ` · ${detail.repository}` : " · global"}
          {detail.parent_job_id ? (
            <>
              {" · "}
              <Link to={`/jobs/${detail.parent_job_id}`}>parent {detail.parent_job_id.slice(0, 8)}</Link>
            </>
          ) : null}
          {detail.reviewer_a_model_id ? ` · A ${detail.reviewer_a_model_id}` : ""}
          {detail.reviewer_b_model_id ? ` · B ${detail.reviewer_b_model_id}` : ""}
        </div>
        {summaryLine(detail) ? (
          <div className="pipe" style={{ borderBottom: 0 }}>
            {summaryLine(detail)}
          </div>
        ) : null}
      </div>

      {detail.risk ? (
        <div className="jobblock">
          <div className="jobhead">
            <span className="t">risk</span>
            <span className={detail.risk.verdict === "auto_approve" ? "st ok" : "st human"}>
              {detail.risk.verdict}
            </span>
            <span className="sha">
              score {detail.risk.score} ≤ appetite {detail.risk.appetite} · {detail.risk.mode}
            </span>
            {detail.risk.safe_unread === true ? <span className="st ok">labeled safe unread</span> : null}
            {detail.risk.safe_unread === false ? <span className="st fail">labeled unsafe</span> : null}
          </div>
          {detail.risk.reasons.length === 0 ? (
            <div className="pipe" style={{ borderBottom: 0 }}>
              no vetoes · score 1
            </div>
          ) : (
            detail.risk.reasons.map((reason, index) => (
              <div
                className="pipe"
                style={{ borderBottom: index === detail.risk!.reasons.length - 1 ? 0 : undefined }}
                key={`${reason.code}-${index}`}
              >
                {reason.code}
                {reason.points != null
                  ? ` ${reason.points > 0 ? "+" : ""}${reason.points}`
                  : ""}{" "}
                · {reason.detail}
              </div>
            ))
          )}
          {detail.status === "succeeded" && detail.risk.safe_unread == null ? (
            <div className="pipe" style={{ borderBottom: 0 }}>
              would you have merged this without reading it?{" "}
              <button
                type="button"
                className="btn"
                disabled={riskLabel.isPending}
                onClick={() => riskLabel.mutate(true)}
              >
                yes
              </button>{" "}
              <button
                type="button"
                className="btn"
                disabled={riskLabel.isPending}
                onClick={() => riskLabel.mutate(false)}
              >
                no
              </button>
            </div>
          ) : null}
          {riskLabel.isError ? <div className="formerr">could not save risk label</div> : null}
        </div>
      ) : null}

      <div className="pagehead">
        <h1>findings</h1>
        <label className="toggle">
          <input
            type="checkbox"
            checked={showDropped}
            onChange={(event) => setShowDropped(event.target.checked)}
          />
          show dropped{droppedCount > 0 ? ` (${droppedCount})` : ""}
        </label>
      </div>
      <FindingsTable
        findings={visibleFindings}
        showDropped={showDropped}
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
      {feedback.isError && !isNotFound(feedback.error) ? (
        <div className="formerr">could not load feedback</div>
      ) : null}
      {send.isError ? <div className="formerr">could not save feedback</div> : null}

      <h1>log tail</h1>
      <div className="jobblock">
        {events.length === 0 ? (
          <div className="pipe" style={{ borderBottom: 0 }}>
            no events yet
          </div>
        ) : (
          events.map((event) => (
            <div className="logline" key={event.id}>
              {event.ts} · {event.level} · {event.message}
              {event.payload_json && (event.level === "warning" || event.level === "error")
                ? ` · ${event.payload_json}`
                : ""}
            </div>
          ))
        )}
      </div>

      <TranscriptViewer jobId={detail.id} live={live} title={detail.title} />
    </div>
  );
}
