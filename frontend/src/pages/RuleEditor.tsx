import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { FormEvent, useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import type { RulePayload, RuleUpsert, Severity } from "../api";
import { createRule, deleteRule, getRule, listRepositories, promoteRule, updateRule } from "../client";

function instructionOf(payload: RulePayload): string {
  return "instruction" in payload ? payload.instruction : "";
}

function payloadSummary(payload: RulePayload | undefined): string {
  if (!payload) return "";
  if ("instruction" in payload) return payload.instruction;
  return JSON.stringify(payload, null, 2);
}

export function RuleEditorPage() {
  const { id } = useParams();
  const isNew = id === undefined;
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const existing = useQuery({
    queryKey: ["rule", id],
    queryFn: () => getRule(id ?? ""),
    enabled: !isNew && Boolean(id),
  });
  const repos = useQuery({ queryKey: ["repositories"], queryFn: listRepositories });

  const [title, setTitle] = useState("");
  const [severity, setSeverity] = useState<Severity>("warning");
  const [instruction, setInstruction] = useState("");
  const [pathGlobs, setPathGlobs] = useState("**/*");
  const [languages, setLanguages] = useState("*");
  const [repository, setRepository] = useState("");
  const [body, setBody] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const rule = existing.data;
    if (!rule) return;
    setTitle(rule.title);
    setSeverity(rule.severity);
    setInstruction(instructionOf(rule.payload));
    setPathGlobs(rule.path_globs.join("\n") || "**/*");
    setLanguages(rule.languages.join(", "));
    setRepository(rule.repository ?? "");
    setBody(rule.body);
  }, [existing.data]);

  const save = useMutation({
    mutationFn: async () => {
      const globs = pathGlobs
        .split(/\n|,/)
        .map((item) => item.trim())
        .filter(Boolean);
      const langs = languages
        .split(",")
        .map((item) => item.trim())
        .filter(Boolean);
      const existingPayload = existing.data?.payload;
      const payload: RuleUpsert = {
        title,
        severity,
        kind: existing.data?.kind ?? "semantic",
        languages: langs.length ? langs : ["*"],
        path_globs: globs.length ? globs : ["**/*"],
        repository: repository.trim() || null,
        payload:
          existingPayload && !("instruction" in existingPayload)
            ? existingPayload
            : { instruction, few_shots: [] },
        body,
      };
      if (isNew) {
        return createRule(payload);
      }
      return updateRule(id, payload);
    },
    onSuccess: (rule) => {
      void queryClient.invalidateQueries({ queryKey: ["rules"] });
      void queryClient.invalidateQueries({ queryKey: ["rule", rule.id] });
      void queryClient.invalidateQueries({ queryKey: ["repositories"] });
      navigate(`/rules/${rule.id}`);
    },
    onError: (err: Error) => setError(err.message),
  });

  const remove = useMutation({
    mutationFn: () => deleteRule(id ?? ""),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["rules"] });
      navigate("/rules");
    },
  });

  const promote = useMutation({
    mutationFn: () => promoteRule(id ?? ""),
    onSuccess: (rule) => {
      void queryClient.invalidateQueries({ queryKey: ["rules"] });
      navigate(`/rules/${rule.id}`);
    },
  });

  if (!isNew && existing.isLoading) {
    return (
      <div className="page">
        <h1>rule</h1>
        <div className="empty">loading…</div>
      </div>
    );
  }

  if (!isNew && existing.isError) {
    return (
      <div className="page">
        <h1>rule</h1>
        <div className="empty">rule not found</div>
      </div>
    );
  }

  const rule = existing.data;
  const canPromote = rule && rule.provenance !== "handwritten";
  const isSemantic = isNew || (rule !== undefined && "instruction" in rule.payload);

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    if (!title.trim()) {
      setError("title is required");
      return;
    }
    if (isSemantic && !instruction.trim()) {
      setError("instruction is required");
      return;
    }
    save.mutate();
  }

  return (
    <div className="page">
      <div className="pagehead">
        <h1>{isNew ? "new semantic rule" : rule?.id}</h1>
        <Link to="/rules">back to list</Link>
      </div>
      <form className="form" onSubmit={onSubmit}>
        <label>
          title
          <input value={title} onChange={(event) => setTitle(event.target.value)} required />
        </label>
        <label>
          severity
          <select value={severity} onChange={(event) => setSeverity(event.target.value as Severity)}>
            <option value="info">info</option>
            <option value="warning">warning</option>
            <option value="error">error</option>
          </select>
        </label>
        {isSemantic ? (
          <label>
            instruction
            <textarea
              rows={6}
              value={instruction}
              onChange={(event) => setInstruction(event.target.value)}
              required
            />
          </label>
        ) : (
          <label>
            checker payload
            <textarea rows={4} value={payloadSummary(rule?.payload)} readOnly />
          </label>
        )}
        <label>
          path globs (one per line, default **/*)
          <textarea rows={3} value={pathGlobs} onChange={(event) => setPathGlobs(event.target.value)} />
        </label>
        <label>
          languages (comma, * for all)
          <input value={languages} onChange={(event) => setLanguages(event.target.value)} />
        </label>
        <label>
          repository (blank = global)
          <input
            list="known-repos"
            value={repository}
            onChange={(event) => setRepository(event.target.value)}
            placeholder="global"
          />
        </label>
        <label>
          body
          <textarea rows={4} value={body} onChange={(event) => setBody(event.target.value)} />
        </label>
        {error ? <div className="formerr">{error}</div> : null}
        <div className="formrow">
          <button type="submit" className="btn" disabled={save.isPending}>
            {isNew ? "create" : "save"}
          </button>
          {!isNew ? (
            <button type="button" className="btn" onClick={() => remove.mutate()} disabled={remove.isPending}>
              delete
            </button>
          ) : null}
          {canPromote ? (
            <button type="button" className="btn" onClick={() => promote.mutate()} disabled={promote.isPending}>
              promote
            </button>
          ) : null}
        </div>
      </form>
      <datalist id="known-repos">
        {(repos.data?.repositories ?? []).map((name) => (
          <option key={name} value={name} />
        ))}
      </datalist>
    </div>
  );
}