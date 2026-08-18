import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import type { TranscriptPhase } from "../api";
import { getJobTranscript, isNotFound } from "../client";

const phases: TranscriptPhase[] = ["review_a", "review_b", "judge"];

export function TranscriptViewer({
  jobId,
  live,
}: {
  jobId: string;
  live: boolean;
}) {
  const [phase, setPhase] = useState<TranscriptPhase>("review_a");
  const transcript = useQuery({
    queryKey: ["job", jobId, "transcript", phase],
    queryFn: () => getJobTranscript(jobId, phase),
    refetchInterval: live ? 2000 : false,
    retry: false,
  });

  return (
    <div className="jobblock">
      <div className="jobhead">
        <span className="t">transcript</span>
        <div className="rxn" style={{ marginTop: 0 }}>
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
      {transcript.isError && isNotFound(transcript.error) ? (
        <div className="pipe" style={{ borderBottom: 0 }}>
          no redacted NDJSON for {phase} yet
        </div>
      ) : transcript.isError ? (
        <div className="formerr">could not load transcript for {phase}</div>
      ) : (
        <pre className="transcript">{transcript.data || "…"}</pre>
      )}
    </div>
  );
}
