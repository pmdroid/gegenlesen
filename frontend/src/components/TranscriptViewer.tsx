import { useQuery } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import type { TranscriptPhase } from "../api";
import { getJobTranscript, isNotFound } from "../client";
import { parseOpenCodeTranscript, type TranscriptEvent } from "../parseTranscript";

const reviewPhases: TranscriptPhase[] = ["review_a", "review_b", "judge"];
const harvestPhases: TranscriptPhase[] = ["mine", "suggestion_judge"];

function phasesForTitle(title: string | null | undefined): TranscriptPhase[] {
  const value = title ?? "";
  if (value.startsWith("harvest") || value.startsWith("learn ")) {
    return harvestPhases;
  }
  return reviewPhases;
}

function EventRow({ event }: { event: TranscriptEvent }) {
  if (event.kind === "tool") {
    return (
      <details className={`tx tx-${event.kind}`}>
        <summary>
          <span className="txk">{event.status === "completed" ? "tool" : event.status ?? "tool"}</span>
          {event.title}
        </summary>
        {event.body ? <pre>{event.body}</pre> : <div className="txempty">no output yet</div>}
      </details>
    );
  }
  return (
    <div className={`tx tx-${event.kind}`}>
      <div className="txh">
        <span className="txk">{event.kind === "meta" ? "step" : event.kind}</span>
        {event.title}
      </div>
      {event.body ? <pre>{event.body}</pre> : null}
    </div>
  );
}

export function TranscriptViewer({
  jobId,
  live,
  title,
}: {
  jobId: string;
  live: boolean;
  title?: string | null;
}) {
  const phases = phasesForTitle(title);
  const [phase, setPhase] = useState<TranscriptPhase>(phases[0] ?? "review_a");
  const scroller = useRef<HTMLDivElement>(null);
  const stick = useRef(true);
  const transcript = useQuery({
    queryKey: ["job", jobId, "transcript", phase],
    queryFn: () => getJobTranscript(jobId, phase),
    refetchInterval: live ? 1000 : false,
    retry: false,
  });

  const raw = transcript.data ?? "";
  const parsed = parseOpenCodeTranscript(raw);
  const waiting = live && transcript.isError && isNotFound(transcript.error);

  useEffect(() => {
    stick.current = true;
  }, [phase]);

  useEffect(() => {
    const node = scroller.current;
    if (!node || !stick.current) return;
    node.scrollTop = node.scrollHeight;
  }, [raw, phase]);

  return (
    <div className="jobblock">
      <div className="jobhead">
        <span className="t">transcript</span>
        {live ? <span className="st run">live</span> : null}
        <div className="rxn" style={{ marginTop: 0, marginLeft: "auto" }}>
          {phases.map((item) => (
            <button
              key={item}
              type="button"
              className={phase === item ? "on" : undefined}
              onClick={() => setPhase(item)}
            >
              {item}
            </button>
          ))}
        </div>
      </div>
      {transcript.isError && !waiting ? (
        isNotFound(transcript.error) ? (
          <div className="pipe" style={{ borderBottom: 0 }}>
            no transcript for {phase}
          </div>
        ) : (
          <div className="formerr">could not load transcript for {phase}</div>
        )
      ) : waiting || (!raw && live) ? (
        <div className="pipe" style={{ borderBottom: 0 }}>
          waiting for {phase}…
        </div>
      ) : parsed.events.length === 0 ? (
        <pre className="transcript">{raw || "…"}</pre>
      ) : (
        <div
          className="txlist"
          ref={scroller}
          onScroll={(event) => {
            const node = event.currentTarget;
            stick.current = node.scrollHeight - node.scrollTop - node.clientHeight < 48;
          }}
        >
          {parsed.events.map((event) => (
            <EventRow key={event.id} event={event} />
          ))}
          {parsed.partial && live ? <div className="tx tx-meta">streaming…</div> : null}
        </div>
      )}
    </div>
  );
}
