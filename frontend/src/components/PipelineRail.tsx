import type { JobStatus } from "../api";
import { PIPELINE_STEPS, activePipelineStep } from "../pipeline";

export function PipelineRail({ status }: { status: JobStatus }) {
  const active = activePipelineStep(status);
  const index = PIPELINE_STEPS.indexOf(active);
  return (
    <div className="phases">
      {PIPELINE_STEPS.map((step, i) => (
        <span key={step} className={i === index ? "on" : i < index ? "done" : undefined}>
          {step}
        </span>
      ))}
    </div>
  );
}
