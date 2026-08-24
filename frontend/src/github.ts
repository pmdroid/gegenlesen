import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import type { JobListItem } from "./api";
import { githubRepoParts, isArchiveTitle } from "./pipeline";

async function pullNumberForCommit(owner: string, repo: string, sha: string): Promise<number | null> {
  const url = `https://api.github.com/repos/${owner}/${repo}/commits/${sha}/pulls`;
  const res = await fetch(url, { headers: { Accept: "application/vnd.github+json" } });
  if (!res.ok) return null;
  const data: unknown = await res.json();
  if (!Array.isArray(data) || data.length === 0) return null;
  const first = data[0] as { number?: unknown };
  return typeof first.number === "number" ? first.number : null;
}

export function usePullNumbers(jobs: JobListItem[]): Record<string, number> {
  const targets = useMemo(() => {
    const seen = new Set<string>();
    const list: { owner: string; repo: string; sha: string }[] = [];
    for (const job of jobs) {
      if (!isArchiveTitle(job.title) || !job.head_sha) continue;
      const github = githubRepoParts(job.repository);
      if (!github) continue;
      const key = `${github.owner}/${github.repo}@${job.head_sha}`;
      if (seen.has(key)) continue;
      seen.add(key);
      list.push({ ...github, sha: job.head_sha });
      if (list.length >= 40) break;
    }
    return list;
  }, [jobs]);

  const query = useQuery({
    queryKey: ["github-pulls", targets.map((item) => `${item.owner}/${item.repo}@${item.sha}`)],
    enabled: targets.length > 0,
    staleTime: Infinity,
    retry: false,
    queryFn: async () => {
      const map: Record<string, number> = {};
      for (const item of targets) {
        const number = await pullNumberForCommit(item.owner, item.repo, item.sha);
        if (number != null) map[item.sha] = number;
      }
      return map;
    },
  });

  return query.data ?? {};
}
