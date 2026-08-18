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

function verdictClass(finding: Finding): string {
  if (finding.phase === "deterministic") return "verdict det";
  if (finding.judge_verdict === "drop") return "verdict dropped";
  if (finding.judge_verdict) return "verdict kept";
  return "verdict det";
}

function verdictLabel(finding: Finding): string {
  if (finding.phase === "deterministic") return "deterministic";
  if (finding.judge_verdict) return `judge: ${finding.judge_verdict}`;
  return finding.phase;
}

export function FindingsTable({
  findings,
  feedback,
  onFeedback,
  pending,
}: {
  findings: Finding[];
  feedback: FindingFeedback[];
  onFeedback: (findingId: string, body: FindingFeedbackRequest) => void;
  pending: boolean;
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
    return <div className="empty">No findings yet.</div>;
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

  return (
    <div className="finding">
      <div className="fh">
        <span className="id">{finding.id}</span>
        <span className="title">{finding.title}</span>
        <span className={verdictClass(finding)}>{verdictLabel(finding)}</span>
        <span className={`st ${finding.severity === "error" ? "fail" : finding.severity === "warning" ? "run" : "ok"}`}>
          {finding.severity}
        </span>
      </div>
      {finding.snippet ? <pre>{finding.snippet}</pre> : null}
      <div className="src">
        {finding.reviewer_slot ?? "host"} · {loc(finding)}
        {finding.rule_id ? ` · rule: ${finding.rule_id}` : ""}
        {finding.message ? ` · ${finding.message}` : ""}
      </div>
      {comments.length > 0 ? (
        <div className="logline">
          {comments.map((row) => (
            <div key={row.id}>{row.comment}</div>
          ))}
        </div>
      ) : null}
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
          💬 comment
        </button>
        <button
          type="button"
          className={verdict?.verdict === "should_be_rule" ? "on" : undefined}
          disabled={pending}
          onClick={() => onFeedback(finding.id, { verdict: "should_be_rule", comment: comment.trim() || undefined })}
        >
          → should be a rule
        </button>
      </div>
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
