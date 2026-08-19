import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { acceptLearning, dismissLearning, listLearnings } from "../client";

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
    mutationFn: (id: string) => dismissLearning(id),
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
          <div className="learn" key={item.id}>
            <div className="pagehead">
              <span className="rn">{item.title}</span>
              <span className="rk">
                {item.kind} · {item.status}
              </span>
            </div>
            <div className="ctx">{item.body}</div>
            <div className="formrow">
              <button
                type="button"
                className="btn"
                disabled={accept.isPending}
                onClick={() => accept.mutate(item.id)}
              >
                accept
              </button>
              <button
                type="button"
                className="btn"
                disabled={dismiss.isPending}
                onClick={() => dismiss.mutate(item.id)}
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
