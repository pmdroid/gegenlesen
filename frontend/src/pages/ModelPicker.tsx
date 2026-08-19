import { useMemo, useState } from "react";
import type { OpenRouterModel } from "../api";

type Props = {
  label: string;
  value: string;
  onChange: (id: string) => void;
  models: OpenRouterModel[];
  suggestions: OpenRouterModel[];
  disabled: boolean;
  placeholder: string;
};

function matches(model: OpenRouterModel, q: string): boolean {
  if (!q) return true;
  const hay = `${model.id} ${model.name} ${model.description ?? ""}`.toLowerCase();
  return q.split(/\s+/).filter(Boolean).every((part) => hay.includes(part));
}

export function ModelPicker({
  label,
  value,
  onChange,
  models,
  suggestions,
  disabled,
  placeholder,
}: Props) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const selected = models.find((model) => model.id === value);
  const filtered = useMemo(() => {
    const query = q.trim().toLowerCase();
    const pool = query ? models : suggestions.length ? suggestions : models;
    return pool.filter((model) => matches(model, query)).slice(0, 40);
  }, [models, suggestions, q]);

  return (
    <label className="picker">
      {label}
      <input
        disabled={disabled}
        value={open ? q : selected?.name ?? value}
        placeholder={placeholder}
        onFocus={() => {
          setOpen(true);
          setQ("");
        }}
        onChange={(event) => {
          setOpen(true);
          setQ(event.target.value);
        }}
        onBlur={() => {
          window.setTimeout(() => setOpen(false), 120);
        }}
      />
      {value ? <div className="picker-id">{value}</div> : null}
      {open && !disabled ? (
        <div className="picker-menu">
          {!q.trim() && suggestions.length > 0 ? <div className="picker-hint">ranked by OpenRouter</div> : null}
          {filtered.length === 0 ? <div className="picker-hint">no models match</div> : null}
          {filtered.map((model) => (
            <button
              type="button"
              key={model.id}
              className={model.id === value ? "on" : undefined}
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => {
                onChange(model.id);
                setQ("");
                setOpen(false);
              }}
            >
              <span className="picker-name">
                {model.name}
                {model.free ? <span className="picker-free"> free</span> : null}
              </span>
              <span className="picker-id">{model.id.replace(/^openrouter\//, "")}</span>
            </button>
          ))}
        </div>
      ) : null}
    </label>
  );
}
