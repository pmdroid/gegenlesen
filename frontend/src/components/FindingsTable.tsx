import { FormEvent, useMemo, useState } from "react";
import type { Finding, FindingFeedback, FindingFeedbackRequest } from "../api";

function currentVerdict(rows: FindingFeedback[]): FindingFeedback | undefined {
  return [...rows].reverse().find((row) => row.verdict !== "comment");
}

function currentReaction(rows: FindingFeedback[]): "thumbs_up" | "thumbs_down" | null {
  const latest = [...rows].reverse().find((row) => row.verdict === "agree" || row.verdict === "disagree");
  return latest?.reaction ?? null;
}

function loc(finding: Finding): string {
  if (!finding.file_path) return "—";
  if (finding.start_line == null) return finding.file_path;
  if (finding.end_line != null && finding.end_line !== finding.start_line) {
    return `${finding.file_path}:${finding.start_line}-${finding.end_line}`;
  }
  return `${finding.file_path}:${finding.start_line}`;
}

export function FindingsTable({
  findings,
  feedback,
  onFeedback,
  pending,
  emptyLabel = "No findings yet.",
}: {
  findings: Finding[];
  feedback: FindingFeedback[];
  onFeedback: (findingId: string, body: FindingFeedbackRequest) => void;
  pending: boolean;
  emptyLabel?: string;
}) {
  const byFinding = useMemo(() => {
    const map = new Map<string, FindingFeedback[]>();
    for (const row of feedback) {
      const list = map.get(row.finding_id) ?? [];
      list.push(row);
      map.set(row.finding_id, list);
    }
    return map;
  }, [feedback]);

  if (findings.length === 0) {
    return <div className="empty">{emptyLabel}</div>;
  }

  return (
    <div>
      {findings.map((finding) => (
        <FindingRow
          key={finding.id}
          finding={finding}
          rows={byFinding.get(finding.id) ?? []}
          onFeedback={onFeedback}
          pending={pending}
        />
      ))}
    </div>
  );
}

function FindingRow({
  finding,
  rows,
  onFeedback,
  pending,
}: {
  finding: Finding;
  rows: FindingFeedback[];
  onFeedback: (findingId: string, body: FindingFeedbackRequest) => void;
  pending: boolean;
}) {
  const [commentOpen, setCommentOpen] = useState(false);
  const [comment, setComment] = useState("");
  const reaction = currentReaction(rows);
  const verdict = currentVerdict(rows);
  const comments = rows.filter((row) => row.verdict === "comment" && row.comment);

  function submitComment(event: FormEvent) {
    event.preventDefault();
    const text = comment.trim();
    if (!text) return;
    onFeedback(finding.id, { verdict: "comment", comment: text });
    setComment("");
    setCommentOpen(false);
  }

  const kept = finding.judge_verdict !== "drop";
  const severity = finding.judge_severity ?? finding.severity;

  return (
    <div className="finding">
      <div className="fh">
        <span className={kept ? "verdict kept" : "verdict dropped"}>
          {finding.judge_verdict === "drop"
            ? "dropped"
            : finding.judge_verdict === "unavailable"
              ? "unavailable"
              : finding.judge_verdict === "downgrade"
                ? "downgrade"
                : "kept"}
        </span>
        <span className={`st ${severity === "error" ? "fail" : severity === "warning" ? "run" : "ok"}`}>
          {severity}
        </span>
        <span className="title">{finding.title}</span>
        <div className="rxn">
          <button
            type="button"
            className={reaction === "thumbs_up" ? "on" : undefined}
            disabled={pending}
            onClick={() => onFeedback(finding.id, { reaction: "👍" })}
          >
            👍
          </button>
          <button
            type="button"
            className={reaction === "thumbs_down" ? "on" : undefined}
            disabled={pending}
            onClick={() => onFeedback(finding.id, { reaction: "👎" })}
          >
            👎
          </button>
          <button type="button" disabled={pending} onClick={() => setCommentOpen((open) => !open)}>
            💬
          </button>
          <button
            type="button"
            className={verdict?.verdict === "should_be_rule" ? "on" : undefined}
            disabled={pending}
            onClick={() =>
              onFeedback(finding.id, {
                verdict: "should_be_rule",
                comment: commentOpen ? comment.trim() || undefined : undefined,
              })
            }
          >
            → rule
          </button>
        </div>
      </div>
      <details className="finding-more">
        <summary>description</summary>
        <div className="src">{loc(finding)}</div>
        {finding.message ? <div className="src">{finding.message}</div> : null}
        {finding.snippet ? <pre>{finding.snippet}</pre> : null}
        {comments.length > 0 ? (
          <div className="logline">
            {comments.map((row) => (
              <div key={row.id}>{row.comment}</div>
            ))}
          </div>
        ) : null}
      </details>
      {commentOpen ? (
        <form className="form" onSubmit={submitComment}>
          <label>
            comment
            <textarea value={comment} onChange={(event) => setComment(event.target.value)} rows={3} />
          </label>
          <div className="formrow">
            <button type="submit" className="btn" disabled={pending || !comment.trim()}>
              save comment
            </button>
          </div>
        </form>
      ) : null}
    </div>
  );
}
