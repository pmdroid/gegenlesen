import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import type { Rule, RulePayload } from "../api";
import { disableRule, enableRule, listRules } from "../client";

function payloadKind(payload: RulePayload): string {
  if ("instruction" in payload) return "semantic guidance";
  return payload.checker;
}

function globLabel(rule: Rule): string {
  return rule.path_globs.join(", ") || "**/*";
}

export function RulesPage() {
  const queryClient = useQueryClient();
  const rules = useQuery({ queryKey: ["rules"], queryFn: () => listRules() });
  const toggle = useMutation({
    mutationFn: (rule: Rule) => (rule.enabled ? disableRule(rule.id) : enableRule(rule.id)),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["rules"] });
    },
  });

  const items = rules.data?.rules ?? [];

  return (
    <div className="page">
      <div className="pagehead">
        <h1>rules</h1>
        <Link to="/rules/new" className="btn">
          new semantic rule
        </Link>
      </div>
      {items.length === 0 ? (
        <div className="empty">No rules yet. Seeds appear after the API boots, or create one here.</div>
      ) : (
        items.map((rule) => (
          <div className="rule" key={rule.id}>
            <div className="pagehead">
              <Link to={`/rules/${rule.id}`} className="rn">
                {rule.title}
              </Link>
              <button
                type="button"
                className="btn"
                onClick={() => toggle.mutate(rule)}
                disabled={toggle.isPending}
              >
                {rule.enabled ? "disable" : "enable"}
              </button>
            </div>
            <div className="rk">
              {rule.id} · {rule.kind} · {payloadKind(rule.payload)} · {globLabel(rule)} ·{" "}
              {rule.enabled ? "enabled" : "disabled"} · {rule.provenance}
            </div>
          </div>
        ))
      )}
    </div>
  );
}
