import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { FormEvent, useEffect, useMemo, useState } from "react";
import { HTTPError, improveAgent, listAgents, listRepositories, putAgent, resetAgent } from "../client";

function draftKey(scope: string, id: string): string {
  return `${scope}:${id}`;
}

export function AgentsPage() {
  const queryClient = useQueryClient();
  const [scope, setScope] = useState("global");
  const repository = scope === "global" ? null : scope;
  const agents = useQuery({
    queryKey: ["agents", scope],
    queryFn: () => listAgents(repository),
  });
  const repos = useQuery({ queryKey: ["repositories"], queryFn: listRepositories });
  const [selected, setSelected] = useState("reviewer");
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [instructions, setInstructions] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const items = agents.data?.agents ?? [];
  const current = items.find((agent) => agent.id === selected) ?? items[0];
  const currentId = current?.id ?? selected;
  const key = draftKey(scope, currentId);
  const savedPrompt = current?.prompt ?? "";
  const prompt = drafts[key] ?? savedPrompt;
  const instruction = instructions[key] ?? "";
  const dirty = current !== undefined && prompt !== savedPrompt;
  const miner = agents.data?.miner_model ?? "";
  const required = current?.required_paths ?? [];
  const missing = required.filter((path) => !prompt.includes(path));
  const repoNames = repos.data?.repositories ?? [];

  useEffect(() => {
    if (!items.some((agent) => agent.id === selected) && items[0]) {
      setSelected(items[0].id);
    }
  }, [items, selected]);

  function setPrompt(value: string) {
    setDrafts((prev) => ({ ...prev, [key]: value }));
    setNotice(null);
  }

  const save = useMutation({
    mutationFn: () => putAgent(currentId, prompt, repository),
    onSuccess: (agent) => {
      setError(null);
      setNotice("saved");
      setDrafts((prev) => {
        const next = { ...prev };
        delete next[draftKey(scope, agent.id)];
        return next;
      });
      void queryClient.invalidateQueries({ queryKey: ["agents"] });
    },
    onError: (err) => {
      setNotice(null);
      setError(err instanceof HTTPError ? err.message : "save failed");
    },
  });

  const reset = useMutation({
    mutationFn: () => resetAgent(currentId, repository),
    onSuccess: (agent) => {
      setError(null);
      setNotice(repository ? "restored inherited" : "restored default");
      setDrafts((prev) => {
        const next = { ...prev };
        delete next[draftKey(scope, agent.id)];
        return next;
      });
      void queryClient.invalidateQueries({ queryKey: ["agents"] });
    },
    onError: (err) => {
      setNotice(null);
      setError(err instanceof HTTPError ? err.message : "reset failed");
    },
  });

  const improve = useMutation({
    mutationFn: () =>
      improveAgent(currentId, {
        instruction,
        prompt,
        repository,
      }),
    onSuccess: (body) => {
      setError(null);
      setNotice("improved — save to keep");
      setDrafts((prev) => ({ ...prev, [key]: body.prompt }));
    },
    onError: (err) => {
      setNotice(null);
      setError(err instanceof HTTPError ? err.message : "improve failed");
    },
  });

  const busy = save.isPending || reset.isPending || improve.isPending;
  const canReset = Boolean(current?.customized || dirty);

  function onSave(event: FormEvent) {
    event.preventDefault();
    save.mutate();
  }

  const minerLabel = useMemo(() => miner.replace(/^openrouter\//, ""), [miner]);
  const badge =
    current?.source === "repository"
      ? "this repo"
      : current?.source === "global" && repository
        ? "inherited"
        : current?.source === "global"
          ? "global"
          : "default";

  return (
    <div className="page">
      <div className="pagehead">
        <h1>agents</h1>
      </div>
      <p className="formhint">
        Global prompts apply to every job. A repo override wins for that repository only. Improve
        talks to the miner model over OpenRouter, one agent at a time, and does not save until you
        do.
      </p>
      <div className="filters">
        <label>
          scope
          <select
            aria-label="scope"
            value={scope}
            onChange={(event) => {
              setScope(event.target.value);
              setError(null);
              setNotice(null);
            }}
          >
            <option value="global">global</option>
            {repoNames.map((name) => (
              <option key={name} value={name}>
                {name}
              </option>
            ))}
          </select>
        </label>
      </div>
      {agents.isError ? <div className="formerr">could not load agents</div> : null}
      <div className="agents-layout">
        <div className="agents-nav" role="tablist" aria-label="agents">
          {items.map((agent) => (
            <button
              key={agent.id}
              type="button"
              role="tab"
              aria-selected={agent.id === currentId}
              className={agent.id === currentId ? "on" : undefined}
              onClick={() => {
                setSelected(agent.id);
                setError(null);
                setNotice(null);
              }}
            >
              {agent.id}
              {drafts[draftKey(scope, agent.id)] !== undefined &&
              drafts[draftKey(scope, agent.id)] !== agent.prompt
                ? " · edited"
                : ""}
            </button>
          ))}
        </div>
        {current ? (
          <form className="form agents-form" onSubmit={onSave}>
            <div className="agents-meta">
              <span className="title">{current.id}</span>
              <span className={current.customized ? "verdict kept" : "id"}>{badge}</span>
              {dirty ? <span className="verdict det">unsaved</span> : null}
            </div>
            <p className="formhint">{current.description}</p>
            <p className="formhint">required paths</p>
            <ul className="agent-paths" aria-label="required paths">
              {required.map((path) => (
                <li key={path} className={prompt.includes(path) ? "ok" : "missing"}>
                  {path}
                </li>
              ))}
            </ul>
            {missing.length > 0 ? (
              <div className="formerr">
                prompt is missing required paths: {missing.join(", ")}
              </div>
            ) : null}
            <label htmlFor="agent-prompt">prompt</label>
            <textarea
              id="agent-prompt"
              className="agent-prompt"
              rows={22}
              spellCheck={false}
              value={prompt}
              onChange={(event) => setPrompt(event.target.value)}
            />
            <div className="formrow">
              <button className="btn" type="submit" disabled={busy || !dirty}>
                save
              </button>
              <button
                className="btn"
                type="button"
                disabled={busy || !canReset}
                onClick={() => reset.mutate()}
              >
                {repository ? "reset to inherited" : "reset to default"}
              </button>
            </div>
            <h2>improve with miner</h2>
            <p className="formhint">
              {minerLabel ? `uses ${minerLabel}` : "uses the miner model from setup"}
            </p>
            <label htmlFor="agent-instruction">how should this prompt change</label>
            <textarea
              id="agent-instruction"
              rows={4}
              value={instruction}
              onChange={(event) => {
                const value = event.target.value;
                setInstructions((prev) => ({ ...prev, [key]: value }));
                setNotice(null);
              }}
              placeholder="e.g. insist on reading tests for every changed symbol"
            />
            <div className="formrow">
              <button
                className="btn"
                type="button"
                disabled={busy || instruction.trim().length === 0}
                onClick={() => improve.mutate()}
              >
                {improve.isPending ? "improving…" : "improve"}
              </button>
            </div>
            {notice ? <p className="formok">{notice}</p> : null}
            {error ? <div className="formerr">{error}</div> : null}
          </form>
        ) : null}
      </div>
    </div>
  );
}
