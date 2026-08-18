import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { deleteRule, listInboxRules, promoteRule } from "../client";

export function LearningsPage() {
  const queryClient = useQueryClient();
  const inbox = useQuery({
    queryKey: ["rules", "inbox"],
    queryFn: listInboxRules,
  });
  const accept = useMutation({
    mutationFn: (id: string) => promoteRule(id),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["rules"] });
    },
  });
  const dismiss = useMutation({
    mutationFn: (id: string) => deleteRule(id),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["rules"] });
    },
  });

  const items = inbox.data ?? [];

  return (
    <div className="page">
      <h1>learnings</h1>
      <div className="neverapply">nothing auto-applies — accept promotes, dismiss deletes</div>
      {items.length === 0 ? (
        <div className="empty">
          Suggested and mined rules land here after <code>POST /api/corpus/mine</code> or{" "}
          <code>POST /api/jobs/:id/learn</code>.
        </div>
      ) : (
        items.map((rule) => (
          <div className="learn" key={rule.id}>
            <div className="pagehead">
              <Link to={`/rules/${rule.id}`} className="rn">
                {rule.title}
              </Link>
              <span className="rk">
                {rule.provenance} · {rule.enabled ? "enabled" : "disabled"}
              </span>
            </div>
            <div className="rk">
              {rule.id} · {rule.path_globs.join(", ") || "**/*"}
            </div>
            <div className="formrow">
              <button
                type="button"
                className="btn"
                disabled={accept.isPending}
                onClick={() => accept.mutate(rule.id)}
              >
                accept
              </button>
              <button
                type="button"
                className="btn"
                disabled={dismiss.isPending}
                onClick={() => dismiss.mutate(rule.id)}
              >
                dismiss
              </button>
            </div>
          </div>
        ))
      )}
    </div>
  );
}
