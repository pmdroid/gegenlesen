export function repoLabel(repository: string | null | undefined): string {
  return repository && repository.length > 0 ? repository : "global";
}

export type ScopeFilter = "all" | "global" | string;

export function scopeQuery(filter: ScopeFilter): { repository?: string; unscoped?: boolean } {
  if (filter === "all") return {};
  if (filter === "global") return { unscoped: true };
  return { repository: filter };
}
