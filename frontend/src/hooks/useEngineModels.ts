import { useQuery } from "@tanstack/react-query";
import { listEngineModels } from "../client";
import { engineAuthConfigured, type EngineId } from "../engines";
import type { EngineAuthStatus } from "../api";

export function useEngineModels(engine: EngineId, engineAuth?: Record<string, EngineAuthStatus | boolean>) {
  const configured = engine !== "opencode" && engineAuthConfigured(engine, engineAuth) === true;
  return useQuery({
    queryKey: ["engine-models", engine],
    queryFn: () => listEngineModels(engine),
    enabled: engine !== "opencode" && configured,
    staleTime: 300_000,
    retry: 1,
  });
}
