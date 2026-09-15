#!/usr/bin/env bun
import { mutateApprovedRooms, mutatePendingRooms, readApprovedRooms, readPendingRooms } from '../src/rooms';

function option(name: string) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function usage(): never {
  throw new Error('usage: approve-room.ts <list|approve|revoke> --approved-file /absolute/path --pending-file /absolute/path [--fingerprint 12hex]');
}

const action = process.argv[2];
const approvedPath = option('--approved-file') ?? usage();
const pendingPath = option('--pending-file');
const fingerprint = option('--fingerprint');

if (action === 'list') {
  if (!pendingPath) usage();
  const pending = readPendingRooms(pendingPath);
  console.log(JSON.stringify({ pending: pending.map(item => ({ fingerprint: item.fingerprint, requestedAt: item.requestedAt })) }, null, 2));
} else if (action === 'approve') {
  if (!pendingPath || !fingerprint || !/^[a-f0-9]{12}$/.test(fingerprint)) usage();
  const pending = readPendingRooms(pendingPath);
  const matches = pending.filter(item => item.fingerprint === fingerprint);
  if (matches.length !== 1) throw new Error('fingerprint must match exactly one unexpired pending room');
  const approved = mutateApprovedRooms(approvedPath, current => current.includes(matches[0].room) ? current : [...current, matches[0].room]);
  mutatePendingRooms(pendingPath, current => current.filter(item => item.room !== matches[0].room));
  console.log(JSON.stringify({ approved: fingerprint, approvedRoomCount: approved.length }));
} else if (action === 'revoke') {
  if (!fingerprint || !/^[a-f0-9]{12}$/.test(fingerprint)) usage();
  const approved = readApprovedRooms(approvedPath);
  const matches = approved.filter(room => room.startsWith(fingerprint));
  if (matches.length !== 1) throw new Error('fingerprint must match exactly one approved room');
  const remaining = mutateApprovedRooms(approvedPath, current => current.filter(room => room !== matches[0]));
  console.log(JSON.stringify({ revoked: fingerprint, approvedRoomCount: remaining.length }));
} else {
  usage();
}
