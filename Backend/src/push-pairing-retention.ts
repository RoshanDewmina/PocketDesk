export const PUSH_PAIRING_RETENTION_MS = 365 * 24 * 60 * 60 * 1000;

export function shouldExpirePushPairing(updatedAt: number, now: number, hasActiveAuthority: boolean): boolean {
  return !hasActiveAuthority && updatedAt <= now - PUSH_PAIRING_RETENTION_MS;
}
