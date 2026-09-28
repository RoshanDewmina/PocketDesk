import { createHash, randomBytes } from 'node:crypto';
import type {
  AuthorizationDecision,
  AuthorizationResult,
  GrantRevocation,
  HostBridge,
  HostReadiness,
  InspectionGrant,
  IntentRecord,
  SessionStatus,
} from '../src/mcp/bridge';

export function sha256Base64Url(value: string): string {
  return createHash('sha256').update(value).digest('base64url');
}

export function pkcePair() {
  const verifier = randomBytes(48).toString('base64url');
  return { verifier, challenge: sha256Base64Url(verifier) };
}

export class FakeClock {
  private value: number;
  constructor(start = 1_700_000_000_000) { this.value = start; }
  now = () => this.value;
  advance(ms: number) { this.value += ms; }
}

export type FakeBridgeOptions = {
  hostID: string;
  decision?: AuthorizationDecision;
  readiness?: HostReadiness;
};

/**
 * In-memory fake of the parent's /browser-host bridge, driven manually by
 * tests: `approveNext()`/`denyNext()` resolve the pending authorization,
 * intents/sessions/inspection state are plain maps a test can mutate directly.
 */
export function createFakeBridge(options: FakeBridgeOptions) {
  let decision: AuthorizationDecision = options.decision ?? 'approved';
  let readiness: HostReadiness = options.readiness ?? 'ready';
  let hostOnline = true;
  const intents = new Map<string, IntentRecord>();
  const sessions = new Map<string, SessionStatus & { hostID: string }>();
  const inspectionGrants = new Map<string, InspectionGrant | null>();
  const revokedListeners = new Set<(revocation: GrantRevocation) => void>();
  const stoppedSessions = new Set<string>();
  const authorizationRequests: Array<{ clientName: string; redirectHost: string; code: string }> = [];
  let pendingResolve: ((result: AuthorizationResult) => void) | undefined;
  let nextFrame: { jpeg: Uint8Array; capturedAt: number } | undefined;

  const bridge: HostBridge = {
    async requestAuthorization({ clientName, redirectHost, code, signal }) {
      authorizationRequests.push({ clientName, redirectHost, code });
      if (!hostOnline) return { decision: 'offline' };
      return new Promise(resolve => {
        pendingResolve = value => resolve(value);
        signal.addEventListener('abort', () => resolve({ decision: 'timeout' }), { once: true });
      });
    },
    hostStatus() {
      return hostOnline ? readiness : 'host_offline';
    },
    async createIntent({ hostID, grantId, ttlMs }) {
      const intentID = randomBytes(8).toString('hex');
      const record: IntentRecord = { intentID, hostID, grantId, expiresAt: Date.now() + ttlMs };
      intents.set(intentID, record);
      return record;
    },
    async lookupIntent(intentID) {
      return intents.get(intentID);
    },
    async stopSession(hostID, sessionID) {
      if (stoppedSessions.has(sessionID)) return 'already_ended';
      stoppedSessions.add(sessionID);
      const record = sessions.get(sessionID);
      if (record) record.connection = 'ended';
      return 'stopped';
    },
    async sessionForIntent(intentID) {
      const intent = intents.get(intentID);
      if (!intent) return undefined;
      for (const session of sessions.values()) if (session.hostID === intent.hostID) return session;
      return { readiness, connection: 'none' };
    },
    async inspectionGrant(hostID) {
      return inspectionGrants.get(hostID) ?? null;
    },
    async captureInspectionFrame() {
      if (!nextFrame) throw new Error('no frame configured');
      return nextFrame;
    },
    onGrantRevoked(listener) {
      revokedListeners.add(listener);
      return () => revokedListeners.delete(listener);
    },
  };

  return {
    bridge,
    approveNext(hostID = options.hostID) {
      pendingResolve?.({ decision: 'approved', hostID });
      pendingResolve = undefined;
    },
    denyNext() {
      pendingResolve?.({ decision: 'denied' });
      pendingResolve = undefined;
    },
    goOffline() { hostOnline = false; },
    setReadiness(value: HostReadiness) { readiness = value; },
    setSession(sessionID: string, hostID: string, status: Omit<SessionStatus, 'sessionID'>) {
      sessions.set(sessionID, { ...status, sessionID, hostID });
    },
    setInspectionGrant(hostID: string, grant: InspectionGrant | null) {
      inspectionGrants.set(hostID, grant);
    },
    setNextFrame(jpeg: Uint8Array, capturedAt: number) { nextFrame = { jpeg, capturedAt }; },
    emitGrantRevoked(revocation: GrantRevocation) {
      for (const listener of revokedListeners) listener(revocation);
    },
    authorizationRequests,
  };
}
