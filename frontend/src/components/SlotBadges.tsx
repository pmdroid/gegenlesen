import { formatSlotBadge } from "../engines";

type Slot = {
  label: string;
  engine: string;
  model: string;
};

export function SlotBadges({ slots, compact }: { slots: Slot[]; compact?: boolean }) {
  return (
    <div className={compact ? "slot-badges compact" : "slot-badges"}>
      {slots.map((slot) => (
        <span className="slot-badge" key={slot.label} title={`${slot.label}: ${slot.engine} ${slot.model}`}>
          <span className="slot-badge-label">{slot.label}</span>
          {formatSlotBadge(slot.engine, slot.model)}
        </span>
      ))}
    </div>
  );
}

export function reviewSlots(job: {
  reviewer_a_engine: string;
  reviewer_a_model_id: string;
  reviewer_b_engine: string;
  reviewer_b_model_id: string;
  judge_engine: string;
  judge_model_id: string;
}): Slot[] {
  return [
    { label: "A", engine: job.reviewer_a_engine, model: job.reviewer_a_model_id },
    { label: "B", engine: job.reviewer_b_engine, model: job.reviewer_b_model_id },
    { label: "judge", engine: job.judge_engine, model: job.judge_model_id },
  ];
}
