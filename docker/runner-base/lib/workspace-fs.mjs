import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, resolve, relative } from "node:path";

export const WORKSPACE_ROOT = process.env.GEGENLESEN_WORKSPACE ?? "/workspace";

export function resolveUnderWorkspace(requestPath) {
  const abs = isAbsolute(requestPath) ? resolve(requestPath) : resolve(WORKSPACE_ROOT, requestPath);
  const rel = relative(WORKSPACE_ROOT, abs);
  if (rel.startsWith("..") || rel === "..") {
    throw new Error(`path outside workspace: ${requestPath}`);
  }
  return abs;
}

export function readWorkspaceTextFile(requestPath, line, limit) {
  const abs = resolveUnderWorkspace(requestPath);
  let content = readFileSync(abs, "utf8");
  if (line !== undefined && line !== null) {
    const start = Math.max(1, Number(line));
    const lines = content.split("\n");
    const end = limit !== undefined && limit !== null ? start + Math.max(0, Number(limit)) - 1 : lines.length;
    content = lines.slice(start - 1, end).join("\n");
  }
  return { content };
}

export function writeWorkspaceTextFile(requestPath, content) {
  const abs = resolveUnderWorkspace(requestPath);
  mkdirSync(dirname(abs), { recursive: true });
  writeFileSync(abs, content, "utf8");
}
