import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import type { Learning, LearningDismissReason, LearningDismissRequest } from "../api";
import { acceptLearning, dismissLearning, listLearnings } from "../client";

const dismissReasons: { value: LearningDismissReason; label: string }[] = [
  { value: "duplicate", label: "duplicate" },
  { value: "already_covered", label: "already covered" },
  { value: "too_specific", label: "too specific" },
  { value: "not_a_rule", label: "not a rule" },
  { value: "other", label: "other" },
];

export function LearningsPage() {
  const queryClient = useQueryClient();
  const inbox = useQuery({
    queryKey: ["learnings", "pending"],
    queryFn: () => listLearnings({ status: "pending" }),
  });
  const accept = useMutation({
    mutationFn: (id: string) => acceptLearning(id),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["learnings"] });
      void queryClient.invalidateQueries({ queryKey: ["rules"] });
      void queryClient.invalidateQueries({ queryKey: ["context"] });
    },
  });
  const dismiss = useMutation({
    mutationFn: ({ id, body }: { id: string; body?: LearningDismissRequest }) =>
      dismissLearning(id, body),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["learnings"] });
    },
  });

  const items = inbox.data?.learnings ?? [];

  return (
    <div className="page">
      <h1>learnings</h1>
      <div className="neverapply">nothing auto-applies — accept writes, dismiss hides</div>
      {items.length === 0 ? (
        <div className="empty">
          Rule, architecture, and context suggestions land here after learn
          (job learn, background sweeper, or <code>gegenlesen harvest</code>).
        </div>
      ) : (
        items.map((item) => (
          <LearningCard
            key={item.id}
            item={item}
            acceptPending={accept.isPending}
            dismissPending={dismiss.isPending}
            onAccept={() => accept.mutate(item.id)}
            onDismiss={(body) => dismiss.mutate({ id: item.id, body })}
          />
        ))
      )}
    </div>
  );
}

function LearningCard({
  item,
  acceptPending,
  dismissPending,
  onAccept,
  onDismiss,
}: {
  item: Learning;
  acceptPending: boolean;
  dismissPending: boolean;
  onAccept: () => void;
  onDismiss: (body?: LearningDismissRequest) => void;
}) {
  const [reason, setReason] = useState<"" | LearningDismissReason>("");
  const [comment, setComment] = useState("");

  function submitDismiss() {
    const trimmed = comment.trim();
    if (!reason && !trimmed) {
      onDismiss();
      return;
    }
    onDismiss({
      reason: reason || undefined,
      comment: trimmed || undefined,
    });
  }

  return (
    <div className="learn">
      <div className="pagehead">
        <span className="rn">{item.title}</span>
        <span className="rk">
          {item.kind} · {item.status}
          {item.judged === false ? " · unjudged draft" : ""}
        </span>
      </div>
      <div className="ctx">{item.body}</div>
      <div className="formrow">
        <button type="button" className="btn" disabled={acceptPending} onClick={onAccept}>
          accept
        </button>
        <select
          value={reason}
          disabled={dismissPending}
          onChange={(event) => setReason(event.target.value as "" | LearningDismissReason)}
        >
          <option value="">reason (optional)</option>
          {dismissReasons.map((entry) => (
            <option key={entry.value} value={entry.value}>
              {entry.label}
            </option>
          ))}
        </select>
        <input
          type="text"
          value={comment}
          disabled={dismissPending}
          placeholder="comment (optional)"
          onChange={(event) => setComment(event.target.value)}
        />
        <button type="button" className="btn" disabled={dismissPending} onClick={submitDismiss}>
          dismiss
        </button>
      </div>
    </div>
  );
}
