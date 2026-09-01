import type { EngineAuthStatus } from "./api";

export const ENGINE_IDS = ["opencode", "claude", "codex", "grok", "cursor-agent"] as const;

export type EngineId = (typeof ENGINE_IDS)[number];

export const ENGINE_LABELS: Record<EngineId, string> = {
  opencode: "OpenCode",
  claude: "Claude",
  codex: "Codex",
  grok: "Grok",
  "cursor-agent": "Cursor",
};

export type EngineModel = {
  id: string;
  name: string;
  description?: string;
};

/** Fallback when ACP probe is unavailable (offline / skip-agent). */
export const ENGINE_MODEL_CATALOG: Partial<Record<EngineId, EngineModel[]>> = {};

export type EngineAuthInfo = {
  envVars: string[];
  cliPaths: string[];
  cliSetup: string;
  apiSetup: string;
  inContainer: string;
};

/** How each engine authenticates: CLI login on host and/or API key env vars. */
export const ENGINE_AUTH: Record<EngineId, EngineAuthInfo> = {
  opencode: {
    envVars: ["OPENROUTER_API_KEY"],
    cliPaths: [],
    cliSetup: "OpenCode uses OpenRouter only (no separate CLI login).",
    apiSetup: "Paste an OpenRouter key below, or set OPENROUTER_API_KEY on the host.",
    inContainer: "OpenCode reads the key from container env (never written to disk).",
  },
  claude: {
    envVars: ["ANTHROPIC_API_KEY"],
    cliPaths: ["~/.claude/.credentials.json"],
    cliSetup: "CLI login: run claude login on the host (OAuth stored under ~/.claude).",
    apiSetup: "API key: set ANTHROPIC_API_KEY on the host running GegenlesenAPI.",
    inContainer: "Mount ~/.claude into the API container at $GEGENLESEN_HOST_HOME/.claude (see scripts/docker-run.sh). Keys pass through env.",
  },
  codex: {
    envVars: ["OPENAI_API_KEY", "CODEX_API_KEY"],
    cliPaths: ["~/.codex/auth.json"],
    cliSetup: "CLI login: run codex login on the host (tokens in ~/.codex/auth.json).",
    apiSetup: "API key: set OPENAI_API_KEY or CODEX_API_KEY on the host.",
    inContainer: "Mount ~/.codex into the API container at $GEGENLESEN_HOST_HOME/.codex. Keys pass through env.",
  },
  "cursor-agent": {
    envVars: ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"],
    cliPaths: ["~/.cursor/cli-config.json", "~/.cursor/sdk/auth.json"],
    cliSetup: "CLI login: run agent login on the host (stored in ~/.cursor/sdk/auth.json).",
    apiSetup: "API key: create one at cursor.com/settings and set CURSOR_API_KEY on the host.",
    inContainer: "Mount ~/.cursor into the API container at $GEGENLESEN_HOST_HOME/.cursor. Keys pass through env.",
  },
  grok: {
    envVars: ["XAI_API_KEY", "GROK_API_KEY"],
    cliPaths: ["~/.grok/auth.json"],
    cliSetup: "CLI login: run grok login on the host (stored in ~/.grok/auth.json).",
    apiSetup: "API key: set XAI_API_KEY or GROK_API_KEY on the host.",
    inContainer: "Mount ~/.grok into the API container at $GEGENLESEN_HOST_HOME/.grok. Keys pass through env.",
  },
};

export function normalizeEngine(raw: string | null | undefined): EngineId {
  const trimmed = (raw ?? "").trim();
  if ((ENGINE_IDS as readonly string[]).includes(trimmed)) {
    return trimmed as EngineId;
  }
  return "opencode";
}

export function formatSlotBadge(engine: string | null | undefined, model: string | null | undefined): string {
  const raw = (engine ?? "").trim();
  const known = (ENGINE_IDS as readonly string[]).includes(raw);
  const label = known ? ENGINE_LABELS[raw as EngineId] : raw || "unknown";
  const m = (model ?? "").trim();
  return m ? `${label} · ${m}` : label;
}

export function engineModelCatalog(engine: EngineId): EngineModel[] {
  return ENGINE_MODEL_CATALOG[engine] ?? [];
}

export function hasModelCatalog(_engine: EngineId): boolean {
  return true;
}

export function defaultModelForEngine(engine: EngineId, models?: EngineModel[]): string {
  if (engine === "opencode") return "";
  return models?.[0]?.id ?? engineModelCatalog(engine)[0]?.id ?? "";
}

export function modelPlaceholder(engine: EngineId): string {
  if (engine === "opencode") return "type to filter OpenRouter models";
  return "pick a model from ACP";
}

export function validateModelForEngine(engine: EngineId, model: string): string | null {
  const trimmed = model.trim();
  if (!trimmed) return "model is required";
  if (engine === "opencode") {
    if (!trimmed.includes("/")) {
      return "OpenCode models use provider/model form, e.g. openrouter/…";
    }
    return null;
  }
  if (trimmed.startsWith("openrouter/") || trimmed.includes("/")) {
    return "OpenRouter-style models belong on the OpenCode engine";
  }
  return null;
}

export function reconcileModelForEngine(engine: EngineId, model: string, models?: EngineModel[]): string {
  if (validateModelForEngine(engine, model)) {
    return defaultModelForEngine(engine, models);
  }
  return model;
}

export function engineAuthConfigured(
  engine: EngineId,
  auth: Record<string, EngineAuthStatus | boolean> | undefined
): boolean | null {
  if (!auth) return null;
  const status = auth[engine];
  if (status == null) return null;
  return resolveEngineAuth(status).configured;
}

export function resolveEngineAuth(raw: EngineAuthStatus | boolean): EngineAuthStatus {
  if (typeof raw === "boolean") {
    return { configured: raw, api_key: raw, cli_login: false };
  }
  return raw;
}
