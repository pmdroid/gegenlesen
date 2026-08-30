export const ENGINE_IDS = ["opencode", "claude", "codex", "grok", "cursor-agent"] as const;

export type EngineId = (typeof ENGINE_IDS)[number];

export const ENGINE_LABELS: Record<EngineId, string> = {
  opencode: "OpenCode",
  claude: "Claude",
  codex: "Codex",
  grok: "Grok",
  "cursor-agent": "Cursor",
};

const MODEL_HINTS: Partial<Record<EngineId, string>> = {
  claude: "claude-sonnet-4-5",
  codex: "gpt-5-codex",
  grok: "grok-3",
  "cursor-agent": "composer-2.5",
};

export function normalizeEngine(raw: string | null | undefined): EngineId {
  const trimmed = (raw ?? "").trim();
  if ((ENGINE_IDS as readonly string[]).includes(trimmed)) {
    return trimmed as EngineId;
  }
  return "opencode";
}

export function formatSlotBadge(engine: string | null | undefined, model: string | null | undefined): string {
  const e = normalizeEngine(engine);
  const label = ENGINE_LABELS[e];
  const m = (model ?? "").trim();
  return m ? `${label} · ${m}` : label;
}

export function modelPlaceholder(engine: EngineId): string {
  if (engine === "opencode") return "type to filter OpenRouter models";
  return MODEL_HINTS[engine] ?? "engine model id";
}

export function validateModelForEngine(engine: EngineId, model: string): string | null {
  const trimmed = model.trim();
  if (!trimmed) return "model is required";
  if (engine === "opencode" && !trimmed.includes("/")) {
    return "OpenCode models use provider/model form, e.g. openrouter/…";
  }
  return null;
}
