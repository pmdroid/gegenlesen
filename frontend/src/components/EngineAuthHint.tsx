import { ENGINE_AUTH, ENGINE_LABELS, type EngineId } from "../engines";
import type { EngineAuthStatus } from "../api";

type Props = {
  engine: EngineId;
  engineAuth?: Record<string, EngineAuthStatus | boolean>;
};

function resolveStatus(
  engine: EngineId,
  engineAuth?: Record<string, EngineAuthStatus | boolean>
): EngineAuthStatus | null {
  if (!engineAuth) return null;
  const raw = engineAuth[engine];
  if (raw == null) return null;
  if (typeof raw === "boolean") {
    return { configured: raw, api_key: raw, cli_login: false };
  }
  return raw;
}

export function EngineAuthHint({ engine, engineAuth }: Props) {
  const info = ENGINE_AUTH[engine];
  const status = resolveStatus(engine, engineAuth);

  return (
    <div className="engine-auth-hint">
      <div className="engine-auth-head">
        <span>{ENGINE_LABELS[engine]} auth</span>
        {status?.configured ? <span className="st ok">ready</span> : null}
        {!status?.configured && status != null ? <span className="st fail">not configured</span> : null}
      </div>
      {status?.cli_login ? <p className="formhint st ok-inline">CLI login detected on host.</p> : null}
      {status?.api_key ? <p className="formhint st ok-inline">API key detected on host.</p> : null}
      {!status?.configured && status != null ? (
        <p className="formhint">Use either CLI login or an API key on the host (either is enough).</p>
      ) : null}
      <p className="formhint">{info.inContainer}</p>
    </div>
  );
}
