import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { isTerminal, type JobListItem, type JobStatus } from "../api";
import { listInboxRules, listJobs, listRules } from "../client";

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

function InboxRail() {
  const inbox = useQuery({
    queryKey: ["rules", "inbox"],
    queryFn: listInboxRules,
    refetchInterval: 4000,
  });
  const items = inbox.data ?? [];
  if (items.length === 0) {
    return <div className="ctx">empty — accept / dismiss on /learnings</div>;
  }
  return (
    <>
      {items.slice(0, 8).map((rule) => (
        <div className="learn" key={rule.id}>
          <Link to={`/learnings`} className="rn">
            {rule.title}
          </Link>
          <div className="rk">{rule.provenance}</div>
        </div>
      ))}
    </>
  );
}

function summaryLine(job: JobListItem): string | null {
  const summary = job.summary;
  if (!summary) return null;
  return `${summary.new} new · ${summary.still_open} still_open · ${summary.resolved} resolved · ${summary.relocated} relocated · ${summary.dropped} dropped`;
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
      return job.error_message ? `failed · ${job.error_message}` : "failed";
    case "cancelled":
      return "cancelled";
  }
}

export function JobsPage() {
  const jobs = useQuery({
    queryKey: ["jobs"],
    queryFn: listJobs,
    refetchInterval: 2000,
  });

  const rules = useQuery({
    queryKey: ["rules", "rail"],
    queryFn: () => listRules({ enabled: true }),
    refetchInterval: 2000,
  });

  const items = jobs.data?.jobs ?? [];
  const railRules = rules.data?.rules ?? [];
  const queued = items.filter((job) => job.status === "queued").length;
  const running = items.filter((job) => !isTerminal(job.status) && job.status !== "queued").length;
  const succeeded = items.filter((job) => job.status === "succeeded").length;

  return (
    <div className="layout">
      <div className="stream">
        <div className="logline">$ meister status</div>
        <div className="logline">
          <b>queue:</b> {queued} queued · {running} running · {succeeded} succeeded · this UI is a
          read-only tail — start work with <b>meister review</b>
        </div>
        {items.length === 0 ? (
          <div className="empty">
            No jobs yet. In a repo run <code>meister review</code>.
            <br />
            Jobs appear here only after the CLI POSTs them.
          </div>
        ) : (
          items.map((job) => (
            <div className="jobblock" key={job.id}>
              <div className="jobhead">
                <Link className="t" to={`/jobs/${job.id}`}>
                  {job.title ?? job.id}
                </Link>
                <span className="sha">{shortSHA(job.head_sha ?? job.base_sha)}</span>
                <span className={statusClass(job.status)}>{job.status}</span>
              </div>
              <div className="pipe">{pipelineLine(job)}</div>
              <div className="pipe" style={{ borderBottom: summaryLine(job) ? undefined : 0 }}>
                posted by CLI · scope: {job.scope}
                {job.parent_job_id ? (
                  <>
                    {" · "}
                    <Link to={`/jobs/${job.parent_job_id}`}>parent {job.parent_job_id.slice(0, 8)}</Link>
                  </>
                ) : null}{" "}
                · the browser cannot start, retry, or cancel this job
              </div>
              {summaryLine(job) ? (
                <div className="pipe" style={{ borderBottom: 0 }}>
                  {summaryLine(job)}
                </div>
              ) : null}
            </div>
          ))
        )}
      </div>
      <aside className="rail">
        <h3>Rules (edit in UI)</h3>
        {railRules.length === 0 ? (
          <div className="rule">
            <span className="rn">—</span>
            <br />
            <span className="rk">no enabled rules</span>
          </div>
        ) : (
          railRules.map((rule) => (
            <div className="rule" key={rule.id}>
              <span className="rn">{rule.id}</span>
              <br />
              <span className="rk">
                {rule.kind}
                {"instruction" in rule.payload ? " · semantic guidance" : ""} ·{" "}
                {rule.path_globs.join(", ")} · {rule.enabled ? "enabled" : "disabled"}
              </span>
            </div>
          ))
        )}
        <h3>Context notes (/context)</h3>
        <div className="ctx">User notes will list here.</div>
        <h3>Learnings inbox</h3>
        <InboxRail />
        <div className="neverapply">nothing auto-applies — accept writes, dismiss deletes</div>
      </aside>
    </div>
  );
}
