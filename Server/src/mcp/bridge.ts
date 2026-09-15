export type HostReadiness =
  | 'host_offline'
  | 'permissions_missing'
  | 'display_not_selected'
  | 'browser_access_disabled'
  | 'ready';

export type ConnectionState = 'none' | 'connecting' | 'connected' | 'ended';
export type SessionScope = 'view' | 'control';

export type InspectionGrant = {
  active: boolean;
  expiresAt: number;
  display: string;
  region?: { x: number; y: number; width: number; height: number };
};

export type IntentRecord = {
  intentID: string;
  hostID: string;
  grantId: string;
  expiresAt: number;
};

export type SessionStatus = {
  readiness: HostReadiness;
  connection: ConnectionState;
  scope?: SessionScope;
  sessionID?: string;
  inspection?: InspectionGrant | null;
  failureCode?: string;
};

export type AuthorizationDecision = 'approved' | 'denied' | 'offline' | 'timeout';

export type AuthorizationResult = {
  decision: AuthorizationDecision;
  /**
   * The Mac hostID the approval bound to. Present only when decision === 'approved'.
   * Single-owner design: the caller does not choose hostID up front; the bridge
   * resolves "the" registered Mac at approval time (whichever host answers the
   * /browser-host `mcp_authorize` request), so the authorization code is bound to
   * whatever host actually approved it rather than to a hostID guessed earlier.
   */
  hostID?: string;
};

export type GrantRevocation = { hostID: string; grantId?: string };

/**
 * Bridge the MCP authorization server and tool layer use to reach the single
 * paired Mac host over the existing /browser-host RPC. Implemented by the
 * parent (browser service) process; this module never talks to a WebSocket
 * directly.
 */
export interface HostBridge {
  /** Ask the currently reachable Mac host to approve an MCP client. Resolves hostID itself. */
  requestAuthorization(params: {
    hostID?: string;
    clientName: string;
    redirectHost: string;
    code: string;
    signal: AbortSignal;
  }): Promise<AuthorizationResult>;

  hostStatus(hostID: string): Promise<HostReadiness> | HostReadiness;

  createIntent(params: { hostID: string; grantId: string; ttlMs: number }): Promise<IntentRecord>;
  lookupIntent(intentID: string): Promise<IntentRecord | undefined>;

  stopSession(hostID: string, sessionID: string): Promise<'stopped' | 'already_ended'>;

  sessionForIntent(intentID: string): Promise<SessionStatus | undefined>;

  inspectionGrant(hostID: string): Promise<InspectionGrant | null>;
  captureInspectionFrame(hostID: string, signal: AbortSignal): Promise<{ jpeg: Uint8Array; capturedAt: number }>;

  /**
   * Notifies this module when the Mac revokes a grant (or all grants for a host)
   * through its own local UI, independent of a revoke this module itself issued.
   * Returns an unsubscribe function.
   */
  onGrantRevoked(listener: (revocation: GrantRevocation) => void): () => void;
}
