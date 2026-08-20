import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import type { Rule, RulePayload } from "../api";
import { deleteRule, disableRule, enableRule, listRepositories, listRules } from "../client";
import { repoLabel, scopeQuery, type ScopeFilter } from "../scope";

function payloadKind(payload: RulePayload): string {
  if ("instruction" in payload) return "semantic guidance";
  if (payload.checker === "risk_weight") {
    return payload.veto ? "auto-approve veto" : `auto-approve ${payload.weight > 0 ? "+" : ""}${payload.weight}`;
  }
  return payload.checker;
}

function globLabel(rule: Rule): string {
  return rule.path_globs.join(", ") || "**/*";
}

export function RulesPage() {
  const queryClient = useQueryClient();
  const [scope, setScope] = useState<ScopeFilter>("all");
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const filter = scopeQuery(scope);
  const rules = useQuery({
    queryKey: ["rules", filter],
    queryFn: () => listRules(filter),
  });
  const repos = useQuery({ queryKey: ["repositories"], queryFn: listRepositories });
  const toggle = useMutation({
    mutationFn: (rule: Rule) => (rule.enabled ? disableRule(rule.id) : enableRule(rule.id)),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["rules"] });
    },
  });
  const removeMany = useMutation({
    mutationFn: async (ids: string[]) => {
      for (const id of ids) {
        await deleteRule(id);
      }
    },
    onSuccess: () => {
      setSelected(new Set());
      void queryClient.invalidateQueries({ queryKey: ["rules"] });
    },
  });

  const items = rules.data?.rules ?? [];
  const allSelected = items.length > 0 && items.every((rule) => selected.has(rule.id));
  const repoNames = repos.data?.repositories ?? [];

  function toggleOne(id: string, on: boolean) {
    setSelected((current) => {
      const next = new Set(current);
      if (on) next.add(id);
      else next.delete(id);
      return next;
    });
  }

  const selectedCount = useMemo(() => selected.size, [selected]);

  return (
    <div className="page">
      <div className="pagehead">
        <h1>rules</h1>
        <Link to="/rules/new" className="btn">
          new semantic rule
        </Link>
        <Link to="/rules/new?type=weight" className="btn">
          new auto-approve weight
        </Link>
      </div>
      <div className="filters">
        <select value={scope} onChange={(event) => setScope(event.target.value)}>
          <option value="all">all scopes</option>
          <option value="global">global</option>
          {repoNames.map((name) => (
            <option key={name} value={name}>
              {name}
            </option>
          ))}
        </select>
        <label className="toggle">
          <input
            type="checkbox"
            checked={allSelected}
            onChange={(event) => {
              setSelected(event.target.checked ? new Set(items.map((rule) => rule.id)) : new Set());
            }}
            disabled={items.length === 0}
          />
          select all
        </label>
        <button
          type="button"
          className="btn"
          disabled={selectedCount === 0 || removeMany.isPending}
          onClick={() => removeMany.mutate([...selected])}
        >
          delete selected{selectedCount ? ` (${selectedCount})` : ""}
        </button>
      </div>
      {items.length === 0 ? (
        <div className="empty">No rules yet. Seeds appear after the API boots, or create one here.</div>
      ) : (
        items.map((rule) => (
          <div className="rule rowsel" key={rule.id}>
            <input
              type="checkbox"
              checked={selected.has(rule.id)}
              onChange={(event) => toggleOne(rule.id, event.target.checked)}
              aria-label={`select ${rule.title}`}
            />
            <div className="grow">
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
                {rule.id} · {rule.kind} · {payloadKind(rule.payload)} · {repoLabel(rule.repository)} ·{" "}
                {globLabel(rule)} · {rule.enabled ? "enabled" : "disabled"} · {rule.provenance}
              </div>
            </div>
          </div>
        ))
      )}
    </div>
  );
}
