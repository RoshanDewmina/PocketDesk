import {
  chmodSync,
  closeSync,
  existsSync,
  fsyncSync,
  lstatSync,
  openSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { dirname, isAbsolute } from 'node:path';

const roomPattern = /^[a-f0-9]{64}$/;
const maxControlBytes = 64 * 1024;
const maxApprovedRooms = 256;
const maxPendingRooms = 16;
const lockWaitMs = 500;
const staleLockMs = 30_000;
const waitCell = new Int32Array(new SharedArrayBuffer(4));

export type PendingRoom = {
  room: string;
  fingerprint: string;
  requestedAt: string;
};

type PendingDocument = {
  version: 1;
  pending: PendingRoom[];
};

function requirePrivateRegularFile(path: string, allowMissing = false) {
  if (!isAbsolute(path)) throw new Error('room control paths must be absolute');
  if (!existsSync(path)) {
    if (allowMissing) return;
    throw new Error(`room control file does not exist: ${path}`);
  }
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`room control path must be a regular file: ${path}`);
  if ((stat.mode & 0o077) !== 0) throw new Error(`room control file must not be accessible by group or others: ${path}`);
  if (stat.size > maxControlBytes) throw new Error(`room control file is too large: ${path}`);
}

function atomicPrivateWrite(path: string, body: string) {
  if (!isAbsolute(path)) throw new Error('room control paths must be absolute');
  const temporary = `${path}.tmp-${process.pid}-${crypto.randomUUID()}`;
  let descriptor: number | undefined;
  try {
    descriptor = openSync(temporary, 'wx', 0o600);
    writeFileSync(descriptor, body, { encoding: 'utf8' });
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(temporary, path);
    chmodSync(path, 0o600);
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    if (existsSync(temporary)) unlinkSync(temporary);
  }
}

type ControlLock = { version: 1; pid: number; createdAt: string; nonce: string };

function processIsAlive(pid: number) {
  try { process.kill(pid, 0); return true; }
  catch (error) { return (error as NodeJS.ErrnoException).code !== 'ESRCH'; }
}

function inspectExistingLock(lockPath: string) {
  let stat;
  try { stat = lstatSync(lockPath); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return true;
    throw error;
  }
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0 || stat.size > 1024) {
    throw new Error(`invalid room control lock requires operator recovery: ${lockPath}`);
  }
  let lock: Partial<ControlLock>;
  try { lock = JSON.parse(readFileSync(lockPath, 'utf8')); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return true;
    throw new Error(`invalid room control lock requires operator recovery: ${lockPath}`);
  }
  if (lock.version !== 1 || !Number.isSafeInteger(lock.pid) || (lock.pid ?? 0) < 1 ||
      typeof lock.createdAt !== 'string' || !Number.isFinite(Date.parse(lock.createdAt)) ||
      typeof lock.nonce !== 'string' || !/^[a-f0-9-]{36}$/.test(lock.nonce)) {
    throw new Error(`invalid room control lock requires operator recovery: ${lockPath}`);
  }
  if (Date.now() - Date.parse(lock.createdAt) > staleLockMs && !processIsAlive(lock.pid!)) {
    throw new Error(`stale room control lock requires operator recovery: ${lockPath}`);
  }
  return false;
}

function withControlLock<T>(path: string, action: () => T): T {
  const lockPath = `${path}.lock`;
  const lock: ControlLock = { version: 1, pid: process.pid, createdAt: new Date().toISOString(), nonce: crypto.randomUUID() };
  const deadline = Date.now() + lockWaitMs;
  let descriptor: number | undefined;
  while (descriptor === undefined) {
    try {
      descriptor = openSync(lockPath, 'wx', 0o600);
      writeFileSync(descriptor, `${JSON.stringify(lock)}\n`, { encoding: 'utf8' });
      fsyncSync(descriptor);
      closeSync(descriptor);
    } catch (error) {
      if (descriptor !== undefined) { closeSync(descriptor); descriptor = undefined; }
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
      if (inspectExistingLock(lockPath)) continue;
      if (Date.now() >= deadline) throw new Error(`room control file is busy: ${path}`);
      Atomics.wait(waitCell, 0, 0, 5);
    }
  }
  try {
    return action();
  } finally {
    let owned = false;
    try {
      const current = JSON.parse(readFileSync(lockPath, 'utf8')) as Partial<ControlLock>;
      owned = current.nonce === lock.nonce && current.pid === lock.pid;
    } catch {}
    if (!owned) throw new Error(`room control lock ownership changed: ${lockPath}`);
    unlinkSync(lockPath);
  }
}

export function roomFingerprint(room: string) {
  if (!roomPattern.test(room)) throw new Error('invalid room ID');
  return room.slice(0, 12);
}

export function readApprovedRooms(path: string): string[] {
  requirePrivateRegularFile(path);
  const rooms = readFileSync(path, 'utf8')
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(line => line && !line.startsWith('#'));
  if (rooms.length > maxApprovedRooms || rooms.some(room => !roomPattern.test(room)) || new Set(rooms).size !== rooms.length) {
    throw new Error('approved room file must contain at most 256 unique 64-character lowercase hex room IDs');
  }
  return rooms;
}

function validateApprovedRooms(rooms: string[]) {
  if (rooms.length > maxApprovedRooms || rooms.some(room => !roomPattern.test(room)) || new Set(rooms).size !== rooms.length) {
    throw new Error('cannot write invalid approved room list');
  }
}

function writeApprovedRoomsUnlocked(path: string, rooms: string[]) {
  validateApprovedRooms(rooms);
  atomicPrivateWrite(path, rooms.length ? `${[...rooms].sort().join('\n')}\n` : '');
}

export function mutateApprovedRooms(path: string, mutation: (rooms: string[]) => string[]) {
  return withControlLock(path, () => {
    const next = mutation(readApprovedRooms(path));
    validateApprovedRooms(next);
    writeApprovedRoomsUnlocked(path, next);
    return [...next];
  });
}

export function writeApprovedRooms(path: string, rooms: string[]) {
  return withControlLock(path, () => writeApprovedRoomsUnlocked(path, rooms));
}

export function restoreApprovedRooms(path: string, body: string) {
  if (Buffer.byteLength(body) > maxControlBytes) throw new Error('approved room document is too large');
  const rooms = body.split(/\r?\n/).map(line => line.trim()).filter(line => line && !line.startsWith('#'));
  if (rooms.length > maxApprovedRooms || rooms.some(room => !roomPattern.test(room)) || new Set(rooms).size !== rooms.length) {
    throw new Error('cannot restore invalid approved room document');
  }
  withControlLock(path, () => atomicPrivateWrite(path, body));
}

export function readPendingRooms(path: string, now = Date.now(), ttlSeconds = 300): PendingRoom[] {
  requirePrivateRegularFile(path, true);
  if (!existsSync(path)) return [];
  const body = JSON.parse(readFileSync(path, 'utf8')) as Partial<PendingDocument>;
  if (body.version !== 1 || !Array.isArray(body.pending) || body.pending.length > maxPendingRooms) {
    throw new Error('invalid pending room file');
  }
  return body.pending.filter(item =>
    item && roomPattern.test(item.room) && item.fingerprint === roomFingerprint(item.room) &&
    typeof item.requestedAt === 'string' && Number.isFinite(Date.parse(item.requestedAt)) &&
    now - Date.parse(item.requestedAt) <= ttlSeconds * 1000
  );
}

function writePendingRoomsUnlocked(path: string, pending: PendingRoom[]) {
  if (pending.length > maxPendingRooms) throw new Error('too many pending rooms');
  atomicPrivateWrite(path, `${JSON.stringify({ version: 1, pending } satisfies PendingDocument, null, 2)}\n`);
}

export function mutatePendingRooms(
  path: string,
  mutation: (pending: PendingRoom[]) => PendingRoom[],
  now = Date.now(),
  ttlSeconds = 300,
) {
  return withControlLock(path, () => {
    const next = mutation(readPendingRooms(path, now, ttlSeconds));
    writePendingRoomsUnlocked(path, next);
    return [...next];
  });
}

export function writePendingRooms(path: string, pending: PendingRoom[]) {
  return withControlLock(path, () => writePendingRoomsUnlocked(path, pending));
}

export type RoomApproval = {
  isApproved(room: string): boolean;
  notePending(room: string): string;
};

export function createFileRoomApproval(config: {
  approvedPath: string;
  pendingPath?: string;
  pendingTTLSeconds?: number;
  now?: () => number;
}): RoomApproval {
  readApprovedRooms(config.approvedPath);
  if (config.pendingPath) {
    if (!isAbsolute(config.pendingPath)) throw new Error('room control paths must be absolute');
    if (!existsSync(dirname(config.pendingPath))) throw new Error('pending room directory does not exist');
    readPendingRooms(config.pendingPath, (config.now ?? Date.now)(), config.pendingTTLSeconds);
  }
  const now = config.now ?? Date.now;
  const ttlSeconds = config.pendingTTLSeconds ?? 300;
  if (!Number.isSafeInteger(ttlSeconds) || ttlSeconds < 60 || ttlSeconds > 900) throw new Error('invalid pending room TTL');
  return {
    isApproved(room) {
      try { return readApprovedRooms(config.approvedPath).includes(room); }
      catch { return false; }
    },
    notePending(room) {
      const fingerprint = roomFingerprint(room);
      if (!config.pendingPath) return fingerprint;
      const timestamp = now();
      mutatePendingRooms(config.pendingPath, current => {
        const pending = current.filter(item => item.room !== room);
        pending.push({ room, fingerprint, requestedAt: new Date(timestamp).toISOString() });
        return pending.slice(-maxPendingRooms);
      }, timestamp, ttlSeconds);
      return fingerprint;
    },
  };
}
