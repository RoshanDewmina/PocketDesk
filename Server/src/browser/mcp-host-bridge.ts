import { randomBytes } from 'node:crypto';
import type {
  AuthorizationResult,
  GrantRevocation,
  HostBridge,
  HostReadiness,
  InspectionGrant,
  IntentRecord,
  SessionScope,
  SessionStatus,
} from '../mcp/bridge';

const HOST_ID = /^[a-f0-9]{64}$/;
const SESSION_ID = /^[a-f0-9]{64}$/;
const MAX_INTENT_TTL_MS = 10 * 60 * 1000;
const READINESS = new Set<HostReadiness>([
  'host_offline',
  'permissions_missing',
  'display_not_selected',
  'browser_access_disabled',
  'ready',
]);

export type HostRpcReply =
  | { kind: 'response'; body: unknown }
  | { kind: 'error'; code: string }
  | { kind: 'offline'; code?: string }
  | { kind: 'aborted'; code?: string }
  | { kind: 'timeout' };

export type BrowserMcpHostBridgeDeps = {
  now?: () => number;
  /** Returns one unambiguous authenticated owner host, otherwise undefined. */
  authorizationHostID(): string | undefined;
  hostConnected(hostID: string): boolean;
  request(
    hostID: string,
    operation: 'mcp_authorize' | 'mcp_status',
    body: Record<string, unknown>,
    signal: AbortSignal,
  ): Promise<HostRpcReply>;
  session(hostID: string, sessionID: string): { scope: SessionScope } | undefined;
  stopSession(hostID: string, sessionID: string): boolean;
};

export type BrowserMcpHostBridge = HostBridge & {
  associateSession(params: { intentID: string; hostID: string; sessionID: string; scope: SessionScope }): boolean;
  stop(): void;
};

const isObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

function exactKeys(value: Record<string, unknown>, keys: string[]) {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

export function createBrowserMcpHostBridge(deps: BrowserMcpHostBridgeDeps): BrowserMcpHostBridge {
  const now = deps.now ?? Date.now;
  const intents = new Map<string, IntentRecord>();
  const intentSessions = new Map<string, { hostID: string; sessionID: string; scope: SessionScope }>();
  const revokedListeners = new Set<(revocation: GrantRevocation) => void>();
  let stopped = false;

  const liveIntent = (intentID: string) => {
    const intent = intents.get(intentID);
    if (!intent) return;
    if (intent.expiresAt <= now()) {
      intents.delete(intentID);
      intentSessions.delete(intentID);
      return;
    }
    return intent;
  };

  const bridge: BrowserMcpHostBridge = {
    async requestAuthorization({ hostID: requestedHostID, clientName, redirectHost, code, signal }) {
      if (stopped || signal.aborted) return { decision: 'timeout' };
      const selectedHostID = requestedHostID ?? deps.authorizationHostID();
      if (!selectedHostID || !HOST_ID.test(selectedHostID) || !deps.hostConnected(selectedHostID)) {
        return { decision: 'offline' };
      }
      let reply: HostRpcReply;
      try {
        reply = await deps.request(selectedHostID, 'mcp_authorize', { clientName, redirectHost, code }, signal);
      } catch {
        return { decision: signal.aborted ? 'timeout' : 'offline' };
      }
      if (reply.kind === 'aborted' || reply.kind === 'timeout') return { decision: 'timeout' };
      if (reply.kind === 'offline') return { decision: 'offline' };
      if (reply.kind !== 'response' || !isObject(reply.body)) return { decision: 'denied' };
      if (exactKeys(reply.body, ['approved']) && reply.body.approved === false) return { decision: 'denied' };
      if (exactKeys(reply.body, ['approved', 'hostID']) && reply.body.approved === true &&
          reply.body.hostID === selectedHostID) {
        return { decision: 'approved', hostID: selectedHostID };
      }
      return { decision: 'denied' };
    },

    async hostStatus(hostID) {
      if (stopped || !HOST_ID.test(hostID) || !deps.hostConnected(hostID)) return 'host_offline';
      const controller = new AbortController();
      let reply: HostRpcReply;
      try {
        reply = await deps.request(hostID, 'mcp_status', {}, controller.signal);
      } catch {
        return 'host_offline';
      }
      if (reply.kind !== 'response' || !isObject(reply.body) || !exactKeys(reply.body, ['readiness']) ||
          typeof reply.body.readiness !== 'string' || !READINESS.has(reply.body.readiness as HostReadiness)) {
        return 'host_offline';
      }
      return reply.body.readiness as HostReadiness;
    },

    async createIntent({ hostID, grantId, ttlMs }) {
      if (stopped || !HOST_ID.test(hostID) || !grantId || grantId.length > 200 ||
          !Number.isSafeInteger(ttlMs) || ttlMs < 1 || ttlMs > MAX_INTENT_TTL_MS) {
        throw new Error('invalid_intent');
      }
      const intentID = randomBytes(32).toString('hex');
      const intent: IntentRecord = { intentID, hostID, grantId, expiresAt: now() + ttlMs };
      intents.set(intentID, intent);
      return intent;
    },

    async lookupIntent(intentID) {
      return stopped ? undefined : liveIntent(intentID);
    },

    async stopSession(hostID, sessionID) {
      if (stopped || !HOST_ID.test(hostID) || !SESSION_ID.test(sessionID)) return 'already_ended';
      const association = [...intentSessions.entries()].find(([intentID, candidate]) =>
        liveIntent(intentID) && candidate.hostID === hostID && candidate.sessionID === sessionID,
      );
      if (!association) return 'already_ended';
      if (!deps.stopSession(hostID, sessionID)) return 'already_ended';
      return 'stopped';
    },

    async sessionForIntent(intentID): Promise<SessionStatus | undefined> {
      const intent = stopped ? undefined : liveIntent(intentID);
      if (!intent) return undefined;
      const readiness = await bridge.hostStatus(intent.hostID);
      const association = intentSessions.get(intentID);
      if (!association) return { readiness, connection: 'none', inspection: null };
      const active = deps.session(association.hostID, association.sessionID);
      if (!active) {
        return { readiness, connection: 'ended', scope: association.scope, sessionID: association.sessionID, inspection: null };
      }
      return { readiness, connection: 'connected', scope: active.scope, sessionID: association.sessionID, inspection: null };
    },

    async inspectionGrant(_hostID): Promise<InspectionGrant | null> {
      return null;
    },

    async captureInspectionFrame() {
      throw new Error('inspection_unavailable');
    },

    onGrantRevoked(listener) {
      if (!stopped) revokedListeners.add(listener);
      return () => revokedListeners.delete(listener);
    },

    associateSession({ intentID, hostID, sessionID, scope }) {
      if (stopped || !HOST_ID.test(hostID) || !SESSION_ID.test(sessionID) || (scope !== 'view' && scope !== 'control')) {
        return false;
      }
      const intent = liveIntent(intentID);
      if (!intent || intent.hostID !== hostID || intentSessions.has(intentID)) return false;
      intentSessions.set(intentID, { hostID, sessionID, scope });
      return true;
    },

    stop() {
      if (stopped) return;
      stopped = true;
      intents.clear();
      intentSessions.clear();
      revokedListeners.clear();
    },
  };

  return bridge;
}
