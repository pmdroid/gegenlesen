import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { FormEvent, useState } from "react";
import type { ContextNote } from "../api";
import {
  createContextNote,
  deleteContextNote,
  listContextNotes,
  updateContextNote,
} from "../client";

export function ContextPage() {
  const queryClient = useQueryClient();
  const notes = useQuery({ queryKey: ["context"], queryFn: listContextNotes });
  const [editing, setEditing] = useState<ContextNote | null>(null);
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [always, setAlways] = useState(false);
  const [globs, setGlobs] = useState("");
  const [error, setError] = useState<string | null>(null);

  function reset() {
    setEditing(null);
    setTitle("");
    setBody("");
    setAlways(false);
    setGlobs("");
    setError(null);
  }

  function startEdit(note: ContextNote) {
    setEditing(note);
    setTitle(note.title);
    setBody(note.body);
    setAlways(note.always_include);
    setGlobs(note.path_globs.join("\n"));
    setError(null);
  }

  const save = useMutation({
    mutationFn: async () => {
      const path_globs = globs
        .split(/\n|,/)
        .map((item) => item.trim())
        .filter(Boolean);
      const payload = { title, body, path_globs, always_include: always };
      if (editing) {
        return updateContextNote(editing.id, payload);
      }
      return createContextNote(payload);
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["context"] });
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

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    if (!title.trim() || !body.trim()) {
      setError("title and body are required");
      return;
    }
    save.mutate();
  }

  const items = notes.data?.notes ?? [];

  return (
    <div className="page">
      <div className="pagehead">
        <h1>context</h1>
        <span className="rk">notes + accepted architecture · nothing auto-applies</span>
      </div>
      {items.length === 0 ? (
        <div className="empty">No notes yet. Add a house note or accept an architecture card from /learnings.</div>
      ) : (
        items.map((note) => (
          <div className="learn" key={note.id}>
            <div className="pagehead">
              <span className="rn">{note.title}</span>
              <span className="rk">
                {note.kind}
                {note.always_include ? " · always include" : ""}
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
    </div>
  );
}
