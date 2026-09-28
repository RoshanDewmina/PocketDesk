import { chmodSync, closeSync, existsSync, fsyncSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { isAbsolute } from 'node:path';
import type { SupervisorState } from './stateMachine';

export type PersistedRecord = {
  version: 1;
  state: SupervisorState;
  threadId: string | null;
  workspace: string | null;
  lastTransitionAt: string;
};

export function readPersistedRecord(path: string): PersistedRecord | null {
  if (!isAbsolute(path)) throw new Error('persistence path must be absolute');
  if (!existsSync(path)) return null;
  const raw = JSON.parse(readFileSync(path, 'utf8')) as Partial<PersistedRecord>;
  if (raw.version !== 1 || typeof raw.state !== 'string' || typeof raw.lastTransitionAt !== 'string') {
    throw new Error('invalid persisted supervisor state');
  }
  return {
    version: 1,
    state: raw.state as SupervisorState,
    threadId: raw.threadId ?? null,
    workspace: raw.workspace ?? null,
    lastTransitionAt: raw.lastTransitionAt,
  };
}

export function writePersistedRecord(path: string, record: PersistedRecord) {
  if (!isAbsolute(path)) throw new Error('persistence path must be absolute');
  const temporary = `${path}.tmp-${process.pid}-${crypto.randomUUID()}`;
  const descriptor = openSync(temporary, 'w', 0o600);
  try {
    writeFileSync(descriptor, `${JSON.stringify(record, null, 2)}\n`, { encoding: 'utf8' });
    fsyncSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
  renameSync(temporary, path);
  chmodSync(path, 0o600);
  if (existsSync(temporary)) unlinkSync(temporary);
}

/**
 * States that imply an in-memory child process cannot possibly have survived
 * a supervisor restart. Only human_control is allowed to persist as-is
 * (marked "no agent" by the caller); everything else must come up stopped.
 */
export function coerceRestartState(state: SupervisorState): SupervisorState {
  if (state === 'human_control') return 'human_control';
  return 'stopped';
}
