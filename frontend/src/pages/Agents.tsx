import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { FormEvent, useEffect, useMemo, useState } from "react";
import { HTTPError, improveAgent, listAgents, putAgent, resetAgent } from "../client";

export function AgentsPage() {
  const queryClient = useQueryClient();
  const agents = useQuery({ queryKey: ["agents"], queryFn: listAgents });
  const [selected, setSelected] = useState("reviewer");
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [instructions, setInstructions] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const items = agents.data?.agents ?? [];
  const current = items.find((agent) => agent.id === selected) ?? items[0];
  const currentId = current?.id ?? selected;
  const savedPrompt = current?.prompt ?? "";
  const prompt = drafts[currentId] ?? savedPrompt;
  const instruction = instructions[currentId] ?? "";
  const dirty = current !== undefined && prompt !== savedPrompt;
  const miner = agents.data?.miner_model ?? "";
  const required = current?.required_paths ?? [];
  const missing = required.filter((path) => !prompt.includes(path));

  useEffect(() => {
    if (!items.some((agent) => agent.id === selected) && items[0]) {
      setSelected(items[0].id);
    }
  }, [items, selected]);

  function setPrompt(value: string) {
    setDrafts((prev) => ({ ...prev, [currentId]: value }));
    setNotice(null);
  }

  const save = useMutation({
    mutationFn: () => putAgent(currentId, prompt),
    onSuccess: (agent) => {
      setError(null);
      setNotice("saved");
      setDrafts((prev) => {
        const next = { ...prev };
        delete next[agent.id];
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
    mutationFn: () => resetAgent(currentId),
    onSuccess: (agent) => {
      setError(null);
      setNotice("restored default");
      setDrafts((prev) => {
        const next = { ...prev };
        delete next[agent.id];
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
      }),
    onSuccess: (body) => {
      setError(null);
      setNotice("improved — save to keep");
      setDrafts((prev) => ({ ...prev, [currentId]: body.prompt }));
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

  return (
    <div className="page">
      <div className="pagehead">
        <h1>agents</h1>
      </div>
      <p className="formhint">
        OpenCode prompts. Defaults are prefilled. Changes apply to the next job. Improve talks to
        the miner model over OpenRouter, one agent at a time, and does not save until you do.
      </p>
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
              {drafts[agent.id] !== undefined && drafts[agent.id] !== agent.prompt ? " · edited" : ""}
            </button>
          ))}
        </div>
        {current ? (
          <form className="form agents-form" onSubmit={onSave}>
            <div className="agents-meta">
              <span className="title">{current.id}</span>
              {current.customized ? <span className="verdict kept">custom</span> : <span className="id">default</span>}
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
                reset to default
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
                setInstructions((prev) => ({ ...prev, [currentId]: value }));
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
