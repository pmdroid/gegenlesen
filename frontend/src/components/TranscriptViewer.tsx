import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import type { TranscriptPhase } from "../api";
import { getJobTranscript, isNotFound } from "../client";

const reviewPhases: TranscriptPhase[] = ["review_a", "review_b", "judge"];
const harvestPhases: TranscriptPhase[] = ["mine", "suggestion_judge"];

function phasesForTitle(title: string | null | undefined): TranscriptPhase[] {
  const value = title ?? "";
  if (value.startsWith("harvest") || value.startsWith("learn ")) {
    return harvestPhases;
  }
  return reviewPhases;
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
