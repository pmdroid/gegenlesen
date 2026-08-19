import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { FormEvent, useMemo, useState } from "react";
import type { ContextNote } from "../api";
import {
  createContextNote,
  deleteContextNote,
  listContextNotes,
  listRepositories,
  updateContextNote,
} from "../client";
import { repoLabel, scopeQuery, type ScopeFilter } from "../scope";

export function ContextPage() {
  const queryClient = useQueryClient();
  const [scope, setScope] = useState<ScopeFilter>("all");
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const filter = scopeQuery(scope);
  const notes = useQuery({
    queryKey: ["context", filter],
    queryFn: () => listContextNotes(filter),
  });
  const repos = useQuery({ queryKey: ["repositories"], queryFn: listRepositories });
  const [editing, setEditing] = useState<ContextNote | null>(null);
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [always, setAlways] = useState(false);
  const [globs, setGlobs] = useState("");
  const [repository, setRepository] = useState("");
  const [error, setError] = useState<string | null>(null);

  function reset() {
    setEditing(null);
    setTitle("");
    setBody("");
    setAlways(false);
    setGlobs("");
    setRepository("");
    setError(null);
  }

  function startEdit(note: ContextNote) {
    setEditing(note);
    setTitle(note.title);
    setBody(note.body);
    setAlways(note.always_include);
    setGlobs(note.path_globs.join("\n"));
    setRepository(note.repository ?? "");
    setError(null);
  }

  const save = useMutation({
    mutationFn: async () => {
      const path_globs = globs
        .split(/\n|,/)
        .map((item) => item.trim())
        .filter(Boolean);
      const payload = {
        title,
        body,
        path_globs,
        always_include: always,
        repository: repository.trim() || null,
      };
      if (editing) {
        return updateContextNote(editing.id, payload);
      }
      return createContextNote(payload);
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["context"] });
      void queryClient.invalidateQueries({ queryKey: ["repositories"] });
      reset();
    },
    onError: (err: Error) => setError(err.message),
  });

  const remove = useMutation({
    mutationFn: (id: string) => deleteContextNote(id),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["context"] });
      reset();
    },
  });

  const removeMany = useMutation({
    mutationFn: async (ids: string[]) => {
      for (const id of ids) {
        await deleteContextNote(id);
      }
    },
    onSuccess: () => {
      setSelected(new Set());
      void queryClient.invalidateQueries({ queryKey: ["context"] });
      reset();
    },
  });

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    if (!title.trim() || !body.trim()) {
      setError("title and body are required");
      return;
    }
    save.mutate();
  }

  const items = notes.data?.notes ?? [];
  const repoNames = repos.data?.repositories ?? [];
  const allSelected = items.length > 0 && items.every((note) => selected.has(note.id));
  const selectedCount = useMemo(() => selected.size, [selected]);

  function toggleOne(id: string, on: boolean) {
    setSelected((current) => {
      const next = new Set(current);
      if (on) next.add(id);
      else next.delete(id);
      return next;
    });
  }

  return (
    <div className="page">
      <div className="pagehead">
        <h1>context</h1>
        <span className="rk">notes + accepted architecture · nothing auto-applies</span>
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
              setSelected(event.target.checked ? new Set(items.map((note) => note.id)) : new Set());
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
        <div className="empty">No notes yet. Add a house note or accept an architecture card from /learnings.</div>
      ) : (
        items.map((note) => (
          <div className="learn rowsel" key={note.id}>
            <input
              type="checkbox"
              checked={selected.has(note.id)}
              onChange={(event) => toggleOne(note.id, event.target.checked)}
              aria-label={`select ${note.title}`}
            />
            <div className="grow">
              <div className="pagehead">
                <span className="rn">{note.title}</span>
                <span className="rk">
                  {note.kind}
                  {note.always_include ? " · always include" : ""} · {repoLabel(note.repository)}
                </span>
              </div>
              <div className="rk">{note.path_globs.join(", ") || "**/*"}</div>
              <div className="ctx">{note.body}</div>
              <div className="formrow">
                <button type="button" className="btn" onClick={() => startEdit(note)}>
                  edit
                </button>
                <button type="button" className="btn" onClick={() => remove.mutate(note.id)}>
                  delete
                </button>
              </div>
            </div>
          </div>
        ))
      )}
      <form className="form" onSubmit={onSubmit}>
        <h1>{editing ? "edit note" : "new note"}</h1>
        <label>
          title
          <input value={title} onChange={(event) => setTitle(event.target.value)} required />
        </label>
        <label>
          body
          <textarea rows={6} value={body} onChange={(event) => setBody(event.target.value)} required />
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
          path globs (optional, one per line)
          <textarea rows={2} value={globs} onChange={(event) => setGlobs(event.target.value)} />
        </label>
        <label>
          <input
            type="checkbox"
            checked={always}
            onChange={(event) => setAlways(event.target.checked)}
            style={{ width: "auto", display: "inline", marginRight: 8 }}
          />
          always include in review context
        </label>
        {error ? <div className="formerr">{error}</div> : null}
        <div className="formrow">
          <button type="submit" className="btn" disabled={save.isPending}>
            {editing ? "save" : "create"}
          </button>
          {editing ? (
            <button type="button" className="btn" onClick={reset}>
              cancel
            </button>
          ) : null}
        </div>
      </form>
      <datalist id="known-repos">
        {repoNames.map((name) => (
          <option key={name} value={name} />
        ))}
      </datalist>
    </div>
  );
}
