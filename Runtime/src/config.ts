import { isAbsolute } from 'node:path';

export type SupervisorConfig = {
  codexBin: string;
  extraArgs: string[];
  /** Test-only escape hatch: overrides the default `["app-server", ...extraArgs]` spawn args to drive a fake process. */
  spawnArgsOverride?: string[];
  workspaceAllowlist: string[];
  controlDir: string;
  quiesceDeadlineMs: number;
  stopGraceMs: number;
  maxSummaryBytes: number;
  persistencePath: string;
};

function integer(env: Record<string, string | undefined>, name: string, fallback: number, min: number, max: number) {
  const raw = env[name];
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new Error(`${name} must be an integer from ${min} to ${max}`);
  return value;
}

function list(value?: string) {
  return value?.split(',').map((item) => item.trim()).filter(Boolean) ?? [];
}

export function loadSupervisorConfig(env: Record<string, string | undefined>): SupervisorConfig {
  const controlDir = env.POCKETDESK_CONTROL_DIR;
  if (!controlDir || !isAbsolute(controlDir)) throw new Error('POCKETDESK_CONTROL_DIR must be an absolute path');
  const persistencePath = env.POCKETDESK_STATE_PATH;
  if (!persistencePath || !isAbsolute(persistencePath)) throw new Error('POCKETDESK_STATE_PATH must be an absolute path');
  const workspaceAllowlist = list(env.POCKETDESK_WORKSPACE_ALLOWLIST);
  if (workspaceAllowlist.length === 0) throw new Error('POCKETDESK_WORKSPACE_ALLOWLIST must list at least one absolute directory');
  return {
    codexBin: env.POCKETDESK_CODEX_BIN || 'codex',
    extraArgs: list(env.POCKETDESK_CODEX_APP_SERVER_ARGS),
    workspaceAllowlist,
    controlDir,
    quiesceDeadlineMs: integer(env, 'POCKETDESK_QUIESCE_DEADLINE_MS', 15_000, 100, 120_000),
    stopGraceMs: integer(env, 'POCKETDESK_STOP_GRACE_MS', 3_000, 100, 30_000),
    maxSummaryBytes: integer(env, 'POCKETDESK_MAX_SUMMARY_BYTES', 4096, 256, 65_536),
    persistencePath,
  };
}
