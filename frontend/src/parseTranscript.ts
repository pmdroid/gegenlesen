export type TranscriptKind = "step" | "text" | "tool" | "meta" | "raw";

export interface TranscriptEvent {
  id: string;
  kind: TranscriptKind;
  title: string;
  body?: string;
  status?: string;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function toolLabel(part: Record<string, unknown>): string {
  const tool = asString(part.tool) ?? "tool";
  const state = asRecord(part.state);
  const input = asRecord(state?.input);
  const path =
    asString(input?.filePath) ??
    asString(input?.path) ??
    asString(input?.glob) ??
    asString(input?.pattern) ??
    asString(input?.command);
  const title = asString(state?.title);
  if (path) return `${tool} ${path.replace(/^\/workspace\//, "")}`;
  if (title) return `${tool} ${title}`;
  return tool;
}

function toolBody(part: Record<string, unknown>): string | undefined {
  const state = asRecord(part.state);
  const output = asString(state?.output);
  const preview = asString(asRecord(state?.metadata)?.preview);
  const text = output ?? preview;
  if (!text) return undefined;
  return text.length > 4000 ? `${text.slice(0, 4000)}\n…` : text;
}

function formatEvent(object: Record<string, unknown>, index: number): TranscriptEvent {
  const type = asString(object.type) ?? "";
  const part = asRecord(object.part) ?? object;
  const partType = asString(part.type) ?? type;

  if (partType === "step-start" || type === "step_start") {
    return { id: `e${index}`, kind: "step", title: "step" };
  }
  if (partType === "step-finish" || type === "step_finish") {
    const reason = asString(part.reason) ?? "done";
    const tokens = asRecord(part.tokens);
    const input = tokens?.input;
    const output = tokens?.output;
    const cost = part.cost;
    const bits: string[] = [reason];
    if (typeof input === "number" || typeof output === "number") {
      bits.push(`${input ?? "?"} in / ${output ?? "?"} out`);
    }
    if (typeof cost === "number") bits.push(`$${cost.toFixed(4)}`);
    return { id: `e${index}`, kind: "meta", title: bits.join(" · ") };
  }
  if (partType === "text" || type === "text") {
    return {
      id: `e${index}`,
      kind: "text",
      title: "assistant",
      body: asString(part.text) ?? asString(object.text),
    };
  }
  if (type === "error") {
    const err = asRecord(object.error);
    const data = asRecord(err?.data) ?? err ?? object;
    const message =
      asString(data?.message) ??
      asString(err?.message) ??
      asString(object.message) ??
      "provider error";
    const body = asString(data?.responseBody) ?? JSON.stringify(data).slice(0, 800);
    return { id: `e${index}`, kind: "raw", title: `error · ${message}`, body };
  }
  if (partType === "tool" || type === "tool_use" || type === "tool") {
    const state = asRecord(part.state);
    return {
      id: `e${index}`,
      kind: "tool",
      title: toolLabel(part),
      body: toolBody(part),
      status: asString(state?.status),
    };
  }
  return {
    id: `e${index}`,
    kind: "raw",
    title: type || "event",
    body: JSON.stringify(object).slice(0, 500),
  };
}

export function parseOpenCodeTranscript(raw: string): {
  events: TranscriptEvent[];
  partial: boolean;
} {
  const events: TranscriptEvent[] = [];
  if (!raw) return { events, partial: false };
  const lines = raw.split("\n");
  let partial = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim()) continue;
    try {
      const parsed: unknown = JSON.parse(line);
      const object = asRecord(parsed);
      if (object) {
        events.push(formatEvent(object, events.length));
      } else {
        events.push({ id: `e${events.length}`, kind: "raw", title: "log", body: line.slice(0, 2000) });
      }
    } catch {
      const last = i === lines.length - 1 && !raw.endsWith("\n");
      if (last) {
        partial = true;
        continue;
      }
      events.push({ id: `e${events.length}`, kind: "raw", title: "log", body: line.slice(0, 2000) });
    }
  }
  return { events, partial };
}
