import { expect, test } from 'bun:test';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { mutateApprovedRooms, readApprovedRooms, writeApprovedRooms } from '../src/rooms';

const roomA = 'a'.repeat(64);
const roomB = 'b'.repeat(64);

test('cross-process add and revoke serialize without restoring a revoked room', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'pocketdesk-race-'));
  const approvedPath = join(directory, 'approved');
  try {
    writeFileSync(approvedPath, '', { mode: 0o600 }); chmodSync(approvedPath, 0o600);
    writeApprovedRooms(approvedPath, [roomA]);
    const worker = join(import.meta.dir, 'fixtures', 'room-mutation-worker.ts');
    const add = Bun.spawn([process.execPath, worker, approvedPath, 'slow-add', roomB], { stdout: 'pipe', stderr: 'pipe' });
    await Bun.sleep(20);
    const revoke = Bun.spawn([process.execPath, worker, approvedPath, 'revoke', roomA], { stdout: 'pipe', stderr: 'pipe' });
    expect(await Promise.all([add.exited, revoke.exited])).toEqual([0, 0]);
    expect(readApprovedRooms(approvedPath)).toEqual([roomB]);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('simultaneous writers fail closed on a stale dead-owner lock without mutating state', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'pocketdesk-lock-'));
  const approvedPath = join(directory, 'approved');
  const lockPath = `${approvedPath}.lock`;
  try {
    writeFileSync(approvedPath, '', { mode: 0o600 }); chmodSync(approvedPath, 0o600);
    writeApprovedRooms(approvedPath, [roomA]);
    const staleBody = `${JSON.stringify({
      version: 1, pid: 2_000_000_000, createdAt: new Date(Date.now() - 60_000).toISOString(),
      nonce: '11111111-1111-4111-8111-111111111111',
    })}\n`;
    writeFileSync(lockPath, staleBody, { mode: 0o600 });

    const worker = join(import.meta.dir, 'fixtures', 'room-mutation-worker.ts');
    const add = Bun.spawn([process.execPath, worker, approvedPath, 'slow-add', roomB], { stdout: 'pipe', stderr: 'pipe' });
    const revoke = Bun.spawn([process.execPath, worker, approvedPath, 'revoke', roomA], { stdout: 'pipe', stderr: 'pipe' });
    expect(await Promise.all([add.exited, revoke.exited])).toEqual([1, 1]);
    expect(readApprovedRooms(approvedPath)).toEqual([roomA]);
    expect(readFileSync(lockPath, 'utf8')).toBe(staleBody);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('malformed lock fails closed without mutating approved rooms', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pocketdesk-lock-'));
  const approvedPath = join(directory, 'approved');
  const lockPath = `${approvedPath}.lock`;
  try {
    writeFileSync(approvedPath, `${roomA}\n`, { mode: 0o600 }); chmodSync(approvedPath, 0o600);
    writeFileSync(lockPath, 'not-json\n', { mode: 0o600 }); chmodSync(lockPath, 0o600);
    expect(() => mutateApprovedRooms(approvedPath, current => [...current, roomB])).toThrow('requires operator recovery');
    expect(readApprovedRooms(approvedPath)).toEqual([roomA]);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
