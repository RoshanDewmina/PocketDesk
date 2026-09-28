import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { SupervisorConfig } from '../src/config';

const fakeAppServerPath = new URL('./fixtures/fakeAppServer.ts', import.meta.url).pathname;
const scenariosDir = new URL('./fixtures/scenarios', import.meta.url).pathname;

export function freshDir(prefix: string): string {
  return mkdtempSync(join(tmpdir(), prefix));
}

/** Loads a scenario JSON, substituting `__PID_FILE__` with a real temp path, and writes it to a scratch file. */
export function materializeScenario(name: string, scratchDir: string, substitutions: Record<string, string> = {}): string {
  let body = readFileSync(join(scenariosDir, `${name}.json`), 'utf8');
  for (const [key, value] of Object.entries(substitutions)) body = body.replaceAll(key, value);
  const outPath = join(scratchDir, `${name}-${crypto.randomUUID()}.json`);
  writeFileSync(outPath, body, 'utf8');
  return outPath;
}

export function buildConfig(overrides: Partial<SupervisorConfig> & { scenario: string; scratchDir: string; substitutions?: Record<string, string> }): SupervisorConfig {
  const { scenario, scratchDir, substitutions, ...rest } = overrides;
  const scenarioFile = materializeScenario(scenario, scratchDir, substitutions);
  return {
    codexBin: process.execPath,
    extraArgs: [],
    spawnArgsOverride: [fakeAppServerPath, scenarioFile],
    workspaceAllowlist: [scratchDir],
    controlDir: join(scratchDir, 'control'),
    quiesceDeadlineMs: 500,
    stopGraceMs: 1000,
    maxSummaryBytes: 4096,
    persistencePath: join(scratchDir, 'state.json'),
    ...rest,
  };
}
