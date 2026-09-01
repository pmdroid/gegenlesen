import { useMemo, useState } from "react";
import type { OpenRouterModel } from "../api";
import {
  ENGINE_LABELS,
  engineModelCatalog,
  hasModelCatalog,
  modelPlaceholder,
  type EngineId,
  type EngineModel,
} from "../engines";

type Props = {
  label: string;
  engine: EngineId;
  value: string;
  onChange: (id: string) => void;
  models: OpenRouterModel[];
  suggestions: OpenRouterModel[];
  nativeModels?: EngineModel[];
  nativeLoading?: boolean;
  nativeError?: string | null;
  disabled: boolean;
  placeholder: string;
  error?: string | null;
};

type Row = {
  id: string;
  name: string;
  description?: string | null;
  free?: boolean;
};

function matches(row: Row, q: string): boolean {
  if (!q) return true;
  const hay = `${row.id} ${row.name} ${row.description ?? ""}`.toLowerCase();
  return q.split(/\s+/).filter(Boolean).every((part) => hay.includes(part));
}

function toRows(engine: EngineId, models: OpenRouterModel[], staticModels: EngineModel[]): Row[] {
  if (engine === "opencode") {
    return models.map((model) => ({
      id: model.id,
      name: model.name,
      description: model.description,
      free: model.free,
    }));
  }
  return staticModels.map((model) => ({
    id: model.id,
    name: model.name,
    description: model.description,
  }));
}

export function ModelPicker({
  label,
  engine,
  value,
  onChange,
  models,
  suggestions,
  nativeModels,
  nativeLoading,
  nativeError,
  disabled,
  placeholder,
  error,
}: Props) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const staticModels = nativeModels ?? engineModelCatalog(engine);
  const catalog = hasModelCatalog(engine);
  const rows = useMemo(() => toRows(engine, models, staticModels), [engine, models, staticModels]);
  const selected = rows.find((row) => row.id === value);
  const suggestionRows = useMemo((): Row[] => {
    if (engine === "opencode") {
      return toRows(engine, suggestions, staticModels);
    }
    return staticModels.map((model) => ({
      id: model.id,
      name: model.name,
      description: model.description,
    }));
  }, [engine, suggestions, staticModels]);

  const filtered = useMemo(() => {
    const query = q.trim().toLowerCase();
    const pool = query ? rows : suggestionRows.length ? suggestionRows : rows;
    return pool.filter((row) => matches(row, query)).slice(0, 40);
  }, [rows, suggestionRows, q]);

  if (!catalog) {
    return (
      <label className="picker">
        {label}
        <input
          disabled={disabled}
          value={value}
          placeholder={placeholder || modelPlaceholder(engine)}
          spellCheck={false}
          autoComplete="off"
          onChange={(event) => onChange(event.target.value)}
        />
        {value ? <div className="picker-id">{ENGINE_LABELS[engine]} · {value.trim()}</div> : null}
        {error ? <div className="formerr">{error}</div> : null}
      </label>
    );
  }

  const sourceLabel = engine === "opencode" ? "OpenRouter" : `${ENGINE_LABELS[engine]} via ACP`;

  return (
    <label className="picker">
      {label}
      {nativeLoading ? <div className="picker-hint">loading {ENGINE_LABELS[engine]} models from ACP…</div> : null}
      {nativeError ? <div className="formerr">{nativeError}</div> : null}
      <input
        disabled={disabled}
        value={open ? q : selected?.name ?? value}
        placeholder={placeholder || modelPlaceholder(engine)}
        onFocus={() => {
          setOpen(true);
          setQ("");
        }}
        onChange={(event) => {
          setOpen(true);
          setQ(event.target.value);
          if (engine !== "opencode") {
            onChange(event.target.value);
          }
        }}
        onBlur={() => {
          window.setTimeout(() => setOpen(false), 120);
        }}
      />
      {value ? <div className="picker-id">{value}</div> : null}
      {error ? <div className="formerr">{error}</div> : null}
      {open && !disabled ? (
        <div className="picker-menu">
          {!q.trim() && suggestionRows.length > 0 ? (
            <div className="picker-hint">{engine === "opencode" ? "ranked by OpenRouter" : sourceLabel}</div>
          ) : null}
          {filtered.length === 0 ? (
            <div className="picker-hint">
              {engine === "opencode" ? "no models match" : "no ACP models match — type a custom model id"}
            </div>
          ) : null}
          {filtered.map((row) => (
            <button
              type="button"
              key={row.id}
              className={row.id === value ? "on" : undefined}
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => {
                onChange(row.id);
                setQ("");
                setOpen(false);
              }}
            >
              <span className="picker-name">
                {row.name}
              {row.free ? <span className="picker-free"> free</span> : null}
              </span>
              <span className="picker-id">{row.id.replace(/^openrouter\//, "")}</span>
              {row.description ? <span className="picker-desc">{row.description}</span> : null}
            </button>
          ))}
        </div>
      ) : null}
    </label>
  );
}
