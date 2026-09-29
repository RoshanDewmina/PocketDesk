import { DurableObject } from "cloudflare:workers";
import { loadConfig, type Config } from "./config";
import { getEntitlement, hasAccess, roomStatus, setDeviceRoom, touchRoom } from "./entitlement/store";
import { verifyEntitlementToken } from "./entitlement/token";
import { fingerprint, log, logError } from "./log";
import {
  AUTH_TIMEOUT_MS, MESSAGES_PER_SECOND, REMOTE_FEATURE, RENEWAL_FEATURE, iceWithinClientLimits,
  parseAuthenticatedFrame, parseJsonFrame, parseRegister, type ErrorCode, type IceServer, type PeerRole, type RegisterMessage,
} from "./protocol";
import { WindowCounter, allow } from "./ratelimit";
import { turnProviderFromEnv, type TurnProvider } from "./turn";
import { secureEqual, sha256Hex } from "./util";

type Attachment = {
  role?: PeerRole;
  authenticated: boolean;
  pending: boolean;
  connectedAt: number;
  renewable: boolean;
  remoteAware: boolean;
  entitled: boolean;
  entitlementId?: string;
  deviceId?: string;
  entitlementUntil?: number;
  issuedAt?: number;
};

type RoomState = {
  room: string | null;
  client_token_hash: string | null;
  lease_ends_at: number | null;
  blocked: number;
  entitlement_id: string | null;
  last_activity: number;
};

const ROOM_ISSUES_PER_MINUTE = 6;
const MAX_LIVE_SETS = 8;
const MIN_RENEW_AFTER_MS = 5000;
const RENEW_RETRY_MS = 30_000;
const IDLE_DELETE_MS = 30 * 24 * 60 * 60 * 1000;

class IssuanceRateLimited extends Error {}

export class RoomDO extends DurableObject<Env> {
  private readonly config: Config;
  private readonly provider: TurnProvider | undefined;
  private readonly messageCounters = new WeakMap<WebSocket, WindowCounter>();
  private readonly issueCounter = new WindowCounter(ROOM_ISSUES_PER_MINUTE, 60_000);
  private renewalPending = new WeakSet<WebSocket>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.config = loadConfig(env);
    this.provider = turnProviderFromEnv(env);
    ctx.blockConcurrencyWhile(async () => {
      ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS room (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          room TEXT,
          client_token_hash TEXT,
          lease_ends_at INTEGER,
          blocked INTEGER NOT NULL DEFAULT 0,
          entitlement_id TEXT,
          last_activity INTEGER NOT NULL DEFAULT 0
        );
        INSERT OR IGNORE INTO room (id) VALUES (1);
        CREATE TABLE IF NOT EXISTS credentials (
          username TEXT PRIMARY KEY,
          role TEXT NOT NULL,
          issued_at INTEGER NOT NULL,
          expires_at INTEGER NOT NULL
        );
      `);
    });
  }

  // ---- storage helpers -------------------------------------------------------------------

  private state(): RoomState {
    return this.ctx.storage.sql.exec<RoomState>("SELECT room, client_token_hash, lease_ends_at, blocked, entitlement_id, last_activity FROM room WHERE id = 1").one();
  }

  private update(fields: Partial<RoomState>): void {
    const keys = Object.keys(fields) as (keyof RoomState)[];
    if (keys.length === 0) return;
    this.ctx.storage.sql.exec(
      `UPDATE room SET ${keys.map(key => `${key} = ?`).join(", ")} WHERE id = 1`,
      ...keys.map(key => fields[key] as string | number | null),
    );
  }

  private attachment(ws: WebSocket): Attachment {
    return (ws.deserializeAttachment() as Attachment | null) ?? { authenticated: false, pending: false, connectedAt: 0, renewable: false, remoteAware: false, entitled: false };
  }

  private save(ws: WebSocket, attachment: Attachment): void {
    try {
      ws.serializeAttachment(attachment);
    } catch {
      // closed socket: nothing left to remember
    }
  }

  private peer(role: PeerRole): WebSocket | undefined {
    return this.ctx.getWebSockets().find(ws => {
      const attachment = this.attachment(ws);
      return attachment.authenticated && attachment.role === role && ws.readyState === WebSocket.OPEN;
    });
  }

  /** A role's slot is taken by an authenticated peer or by a registration still in flight (digest or relay issuance). */
  private slotTaken(role: PeerRole, except: WebSocket): boolean {
    return this.ctx.getWebSockets().some(ws => {
      if (ws === except || ws.readyState !== WebSocket.OPEN) return false;
      const attachment = this.attachment(ws);
      return attachment.role === role && (attachment.authenticated || attachment.pending);
    });
  }

  private send(ws: WebSocket, value: unknown): void {
    try {
      ws.send(JSON.stringify(value));
    } catch (error) {
      logError("send_failed", error);
    }
  }

  private error(ws: WebSocket, code: ErrorCode, close = true): void {
    this.send(ws, { type: "error", code });
    if (close) this.close(ws, 1008, code);
  }

  private close(ws: WebSocket, code: number, reason: string): void {
    try {
      ws.close(code, reason);
    } catch {
      // already closed
    }
  }

  private async scheduleAlarm(): Promise<void> {
    const now = Date.now();
    let next: number | undefined;
    for (const ws of this.ctx.getWebSockets()) {
      const attachment = this.attachment(ws);
      if (!attachment.authenticated) next = Math.min(next ?? Infinity, attachment.connectedAt + AUTH_TIMEOUT_MS);
    }
    const state = this.state();
    if (state.lease_ends_at && this.peer("host")) next = Math.min(next ?? Infinity, state.lease_ends_at);
    if (next === undefined && this.ctx.getWebSockets().length === 0) next = now + IDLE_DELETE_MS;
    if (next === undefined) {
      await this.ctx.storage.deleteAlarm();
    } else {
      await this.ctx.storage.setAlarm(Math.max(now + 1, next));
    }
  }

  // ---- credentials --------------------------------------------------------------------------

  private rememberIssued(role: PeerRole, servers: IceServer[], now: number): void {
    for (const server of servers) {
      if (!server.username) continue;
      this.ctx.storage.sql.exec(
        "INSERT OR REPLACE INTO credentials (username, role, issued_at, expires_at) VALUES (?, ?, ?, ?)",
        server.username, role, now, now + this.config.turnTtlSeconds * 1000,
      );
    }
    const live = this.ctx.storage.sql.exec<{ username: string }>(
      "SELECT username FROM credentials WHERE role = ? ORDER BY issued_at DESC", role,
    ).toArray();
    const dropped = live.slice(MAX_LIVE_SETS).map(row => row.username);
    if (dropped.length) this.revokeUsernames(dropped);
  }

  private revokeUsernames(usernames: string[]): void {
    if (usernames.length === 0) return;
    this.ctx.storage.sql.exec(`DELETE FROM credentials WHERE username IN (${usernames.map(() => "?").join(",")})`, ...usernames);
    if (!this.provider) return;
    const provider = this.provider;
    this.ctx.waitUntil(provider.revoke(usernames).catch(error => logError("turn_revoke_failed", error, { count: usernames.length })));
  }

  private revokeRole(role: PeerRole): void {
    const usernames = this.ctx.storage.sql.exec<{ username: string }>("SELECT username FROM credentials WHERE role = ?", role).toArray().map(row => row.username);
    this.revokeUsernames(usernames);
  }

  private revokeAll(): void {
    const usernames = this.ctx.storage.sql.exec<{ username: string }>("SELECT username FROM credentials").toArray().map(row => row.username);
    this.revokeUsernames(usernames);
  }

  private async issueServers(role: PeerRole): Promise<IceServer[]> {
    const servers: IceServer[] = this.config.stunUrls.length ? [{ urls: [...this.config.stunUrls] }] : [];
    if (!this.provider) return servers;
    const now = Date.now();
    if (!this.issueCounter.hit(now) || !(await allow(this.env.RL_TURN, "turn", "RL_TURN"))) throw new IssuanceRateLimited();
    const issued = await this.provider.issue();
    const combined = [...servers, ...issued];
    if (!iceWithinClientLimits(combined)) {
      this.revokeUsernames(issued.flatMap(server => server.username ? [server.username] : []));
      throw new Error("relay configuration exceeds client limits");
    }
    this.rememberIssued(role, issued, now);
    return combined;
  }

  // ---- entitlement -------------------------------------------------------------------------

  private async checkEntitlement(token: string | undefined): Promise<{ entitled: boolean; entitlementId?: string; deviceId?: string; until?: number }> {
    if (!token) return { entitled: false };
    const now = Date.now();
    const payload = await verifyEntitlementToken(this.env.ENTITLEMENT_TOKEN_KEY, token, now);
    if (!payload) return { entitled: false };
    let until = payload.x * 1000;
    try {
      const row = await getEntitlement(this.env.DB, payload.s);
      if (!row || !hasAccess(row, now)) return { entitled: false };
      until = Math.min(until, Math.max(row.expires_at, row.grace_until ?? 0));
    } catch (error) {
      logError("entitlement_lookup_failed", error, { entitlement: fingerprint(payload.s) });
    }
    return { entitled: true, entitlementId: payload.s, deviceId: payload.d, until };
  }

  // ---- WebSocket lifecycle -------------------------------------------------------------------

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname !== "/connect" || request.headers.get("upgrade") !== "websocket") return new Response("Not found", { status: 404 });
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair) as [WebSocket, WebSocket];
    this.ctx.acceptWebSocket(server);
    this.save(server, { authenticated: false, pending: false, connectedAt: Date.now(), renewable: false, remoteAware: false, entitled: false });
    await this.scheduleAlarm();
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    const now = Date.now();
    let counter = this.messageCounters.get(ws);
    if (!counter) {
      counter = new WindowCounter(MESSAGES_PER_SECOND, 1000);
      this.messageCounters.set(ws, counter);
    }
    if (!counter.hit(now)) { this.error(ws, "rate_limit"); return; }
    const msg = parseJsonFrame(raw);
    if (!msg) { this.error(ws, "invalid_message"); return; }
    const attachment = this.attachment(ws);
    if (!attachment.authenticated) {
      if (attachment.pending) { this.error(ws, "registration_pending"); return; }
      const register = parseRegister(msg);
      if (!register) { this.error(ws, "invalid_registration"); return; }
      await this.register(ws, attachment, register);
      return;
    }
    const frame = parseAuthenticatedFrame(msg);
    if (frame.kind === "invalid") { this.error(ws, frame.code); return; }
    if (frame.kind === "renew") {
      if (!attachment.renewable) { this.error(ws, "invalid_message"); return; }
      await this.renew(ws, attachment);
      return;
    }
    const other = this.peer(attachment.role === "host" ? "client" : "host");
    if (!other) { this.error(ws, "peer_unavailable", false); return; }
    this.send(other, { type: "signal", payload: frame.payload });
  }

  override async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    this.close(ws, code === 1005 || code === 1006 ? 1000 : code, reason);
    await this.handleClose(ws);
  }

  override async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    logError("socket_error", error);
    this.close(ws, 1011, "error");
    await this.handleClose(ws);
  }

  private async handleClose(ws: WebSocket): Promise<void> {
    const attachment = this.attachment(ws);
    if (attachment.authenticated && attachment.role) {
      this.revokeRole(attachment.role);
      if (attachment.role === "host") {
        this.update({ client_token_hash: null, lease_ends_at: null, entitlement_id: null });
        const client = this.peer("client");
        if (client) {
          this.revokeRole("client");
          this.close(client, 1001, "host_disconnected");
        }
      } else {
        const host = this.peer("host");
        if (host) {
          // No session can use the Mac's relay credential without this phone; issue a fresh one on the next join.
          this.revokeRole("host");
          this.send(host, { type: "peer", online: false });
        }
        this.update({ entitlement_id: null });
      }
    }
    this.save(ws, { ...attachment, authenticated: false, role: undefined });
    await this.scheduleAlarm();
  }

  override async alarm(): Promise<void> {
    const now = Date.now();
    for (const ws of this.ctx.getWebSockets()) {
      const attachment = this.attachment(ws);
      if (!attachment.authenticated && !attachment.pending && attachment.connectedAt + AUTH_TIMEOUT_MS <= now) {
        this.error(ws, "authentication_timeout");
      }
    }
    const state = this.state();
    const host = this.peer("host");
    if (host && state.lease_ends_at !== null && state.lease_ends_at <= now) {
      this.expireRoom(host);
    }
    if (this.ctx.getWebSockets().length === 0 && state.last_activity + IDLE_DELETE_MS <= now) {
      this.revokeAll();
      await this.ctx.storage.deleteAll();
      await this.ctx.storage.deleteAlarm();
      return;
    }
    await this.scheduleAlarm();
  }

  private expireRoom(host: WebSocket): void {
    // Closing the host is the single way a lease ends: its close handler clears the room and closes the client.
    this.close(host, 1001, "room_lifetime_reached");
  }

  // ---- registration ------------------------------------------------------------------------

  private renewalOffer(attachment: Attachment, leaseEndsAt: number, now: number) {
    return {
      version: 1,
      leaseSeconds: this.config.leaseMs / 1000,
      renewAfterSeconds: this.nextRenewAfterMs(attachment, leaseEndsAt, now) / 1000,
      ...(this.provider && attachment.entitled ? { credentialSeconds: this.config.turnTtlSeconds } : {}),
    };
  }

  private nextRenewAfterMs(attachment: Attachment, leaseEndsAt: number, now: number): number {
    const candidates = [Math.max(0, (leaseEndsAt - now) / 2)];
    if (this.provider && attachment.entitled && attachment.issuedAt !== undefined) {
      candidates.push(Math.max(0, attachment.issuedAt + Math.floor(this.config.turnTtlSeconds * 1000 / 3) - now));
    }
    return Math.max(MIN_RENEW_AFTER_MS, Math.floor(Math.min(...candidates)));
  }

  private async register(ws: WebSocket, attachment: Attachment, msg: RegisterMessage): Promise<void> {
    this.save(ws, { ...attachment, pending: true, role: msg.role });
    try {
      await this.registerPeer(ws, attachment, msg);
    } finally {
      const current = this.attachment(ws);
      if (!current.authenticated) this.save(ws, { ...current, pending: false, role: undefined });
    }
  }

  private async registerPeer(ws: WebSocket, attachment: Attachment, msg: RegisterMessage): Promise<void> {
    const now = Date.now();
    const state = this.state();
    const room = msg.room;
    if (state.room && state.room !== room) { this.error(ws, "invalid_registration"); return; }
    const remoteAware = msg.features.has(REMOTE_FEATURE) || msg.entitlement !== undefined;
    const renewable = msg.features.has(RENEWAL_FEATURE);

    if (msg.role === "host") {
      if (this.slotTaken("host", ws)) { this.error(ws, "already_connected"); return; }
      if (!msg.clientTokenHash || !(await secureEqual(await sha256Hex(msg.token), room))) { this.error(ws, "unauthorized"); return; }
      if (state.blocked) { this.error(ws, "room_not_approved"); return; }
      if (!state.room) {
        // First host registration in this object: honour a block recorded in D1 before the object existed.
        try {
          if ((await roomStatus(this.env.DB, room)) === "blocked") {
            this.update({ blocked: 1, room });
            this.error(ws, "room_not_approved");
            return;
          }
        } catch (error) {
          logError("room_status_lookup_failed", error, { room: fingerprint(room) });
        }
      }
      if (ws.readyState !== WebSocket.OPEN) return;
      const leaseEndsAt = now + this.config.leaseMs;
      this.update({ room, client_token_hash: msg.clientTokenHash, lease_ends_at: leaseEndsAt, entitlement_id: null, last_activity: now });
      const next: Attachment = { ...attachment, role: "host", authenticated: true, pending: false, renewable, remoteAware, entitled: false };
      this.save(ws, next);
      this.send(ws, {
        type: "registered",
        role: "host",
        ...(renewable ? { renew: this.renewalOffer(next, leaseEndsAt, now) } : {}),
        ...(remoteAware ? { access: "local" } : {}),
      });
      this.send(ws, { type: "ice", servers: [], ...(this.config.testForceRelay ? { policy: "relay" } : {}) });
      this.ctx.waitUntil(touchRoom(this.env.DB, room, now).catch(error => logError("room_touch_failed", error, { room: fingerprint(room) })));
      log("host_registered", { room: fingerprint(room), renewable });
      await this.scheduleAlarm();
      return;
    }

    const host = this.peer("host");
    if (!host || !state.client_token_hash || !(await secureEqual(await sha256Hex(msg.token), state.client_token_hash))) {
      this.error(ws, "host_unavailable_or_unauthorized");
      return;
    }
    if (this.slotTaken("client", ws)) { this.error(ws, "already_connected"); return; }

    const entitlement = await this.checkEntitlement(msg.entitlement);
    if (remoteAware && !entitlement.entitled) this.error(ws, "entitlement_required", false);

    let clientServers: IceServer[] = [];
    let hostServers: IceServer[] | undefined;
    if (entitlement.entitled) {
      try {
        [clientServers, hostServers] = await Promise.all([this.issueServers("client"), this.issueServers("host")]);
      } catch (error) {
        if (ws.readyState === WebSocket.OPEN) this.error(ws, "relay_unavailable");
        log("relay_issue_failed", { room: fingerprint(room), reason: error instanceof IssuanceRateLimited ? "rate_limited" : "provider" });
        return;
      }
      if (ws.readyState !== WebSocket.OPEN) { this.revokeRole("client"); this.revokeRole("host"); return; }
      if (!this.peer("host")) { this.revokeRole("client"); this.revokeRole("host"); this.error(ws, "host_unavailable_or_unauthorized"); return; }
    } else if (ws.readyState !== WebSocket.OPEN || !this.peer("host")) {
      return;
    }

    const issuedAt = Date.now();
    const leaseEndsAt = this.state().lease_ends_at ?? issuedAt + this.config.leaseMs;
    const next: Attachment = {
      ...attachment, role: "client", authenticated: true, pending: false, renewable, remoteAware,
      entitled: entitlement.entitled, entitlementId: entitlement.entitlementId, deviceId: entitlement.deviceId,
      entitlementUntil: entitlement.until, issuedAt: entitlement.entitled ? issuedAt : undefined,
    };
    this.save(ws, next);
    this.update({ entitlement_id: entitlement.entitlementId ?? null, last_activity: issuedAt });
    const currentHost = this.peer("host")!;
    if (hostServers) {
      const hostAttachment = this.attachment(currentHost);
      this.save(currentHost, { ...hostAttachment, entitled: true, issuedAt });
      this.send(currentHost, { type: "ice", servers: hostServers, ...(this.config.testForceRelay ? { policy: "relay" } : {}) });
    }
    this.send(ws, {
      type: "registered",
      role: "client",
      ...(renewable ? { renew: this.renewalOffer(next, leaseEndsAt, issuedAt) } : {}),
      ...(remoteAware ? { access: entitlement.entitled ? "remote" : "local" } : {}),
    });
    this.send(ws, { type: "ice", servers: clientServers, ...(this.config.testForceRelay ? { policy: "relay" } : {}) });
    this.send(currentHost, { type: "peer", online: true });
    this.send(ws, { type: "peer", online: true });
    if (entitlement.entitled && entitlement.entitlementId && entitlement.deviceId) {
      this.ctx.waitUntil(setDeviceRoom(this.env.DB, entitlement.entitlementId, entitlement.deviceId, room, issuedAt)
        .catch(error => logError("device_room_update_failed", error)));
    }
    log("client_registered", { room: fingerprint(room), entitled: entitlement.entitled, renewable });
    await this.scheduleAlarm();
  }

  // ---- renewal ----------------------------------------------------------------------------

  private async renew(ws: WebSocket, attachment: Attachment): Promise<void> {
    const now = Date.now();
    const state = this.state();
    const host = this.peer("host");
    if (!host || !attachment.role || (attachment.role === "client" && this.peer("client") !== ws) || (attachment.role === "host" && host !== ws)) {
      this.close(ws, 1008, "room_unavailable");
      return;
    }
    if (state.lease_ends_at === null || now >= state.lease_ends_at) { this.expireRoom(host); return; }
    if (state.blocked) { this.terminate("room_not_approved"); return; }
    if (this.renewalPending.has(ws)) {
      this.send(ws, { type: "renewed", leaseSeconds: this.config.leaseMs / 1000, renewAfterSeconds: MIN_RENEW_AFTER_MS / 1000, code: "renewal_pending" });
      return;
    }
    const leaseEndsAt = now + this.config.leaseMs;
    this.update({ lease_ends_at: leaseEndsAt, last_activity: now });
    await this.scheduleAlarm();

    let servers: IceServer[] | undefined;
    let code: string | undefined;
    const refreshDue = this.provider && attachment.entitled && attachment.issuedAt !== undefined &&
      now - attachment.issuedAt >= Math.floor(this.config.turnTtlSeconds * 1000 / 3);
    if (refreshDue) {
      const stillEntitled = await this.stillEntitled(attachment, now);
      if (!stillEntitled) {
        code = "entitlement_required";
      } else {
        this.renewalPending.add(ws);
        try {
          servers = await this.issueServers(attachment.role);
        } catch (error) {
          code = error instanceof IssuanceRateLimited ? "rate_limited" : "relay_unavailable";
        } finally {
          this.renewalPending.delete(ws);
        }
        if (servers) {
          if (ws.readyState !== WebSocket.OPEN) { this.revokeUsernames(servers.flatMap(s => s.username ? [s.username] : [])); return; }
          const refreshed = { ...this.attachment(ws), issuedAt: Date.now() };
          this.save(ws, refreshed);
          attachment = refreshed;
        }
      }
    }
    if (ws.readyState !== WebSocket.OPEN) return;
    const at = Date.now();
    const renewAfterMs = code
      ? Math.max(MIN_RENEW_AFTER_MS, Math.min(RENEW_RETRY_MS, (leaseEndsAt - at) / 2))
      : this.nextRenewAfterMs(attachment, leaseEndsAt, at);
    this.send(ws, {
      type: "renewed",
      leaseSeconds: this.config.leaseMs / 1000,
      renewAfterSeconds: Math.floor(renewAfterMs) / 1000,
      ...(servers ? { servers, credentialSeconds: this.config.turnTtlSeconds } : {}),
      ...(code ? { code } : {}),
    });
  }

  private async stillEntitled(attachment: Attachment, now: number): Promise<boolean> {
    if (!attachment.entitled) return false;
    const entitlementId = attachment.entitlementId ?? this.state().entitlement_id;
    if (!entitlementId) return false;
    if (attachment.role === "client" && attachment.entitlementUntil !== undefined && attachment.entitlementUntil <= now) return false;
    try {
      const row = await getEntitlement(this.env.DB, entitlementId);
      return row !== null && hasAccess(row, now);
    } catch (error) {
      logError("entitlement_lookup_failed", error, { entitlement: fingerprint(entitlementId) });
      return true;
    }
  }

  // ---- operator / system RPC -----------------------------------------------------------------

  private terminate(reason: string): void {
    this.revokeAll();
    for (const ws of this.ctx.getWebSockets()) this.close(ws, 1008, reason);
    this.update({ client_token_hash: null, lease_ends_at: null, entitlement_id: null });
  }

  async revokeEntitlement(entitlementId: string): Promise<boolean> {
    const state = this.state();
    if (state.entitlement_id !== entitlementId) return false;
    log("entitlement_revoked_live", { room: fingerprint(state.room ?? undefined) });
    this.terminate("entitlement_revoked");
    await this.scheduleAlarm();
    return true;
  }

  async block(): Promise<void> {
    this.update({ blocked: 1 });
    this.terminate("room_not_approved");
    await this.scheduleAlarm();
  }

  async unblock(): Promise<void> {
    this.update({ blocked: 0 });
  }

  async forget(): Promise<void> {
    this.revokeAll();
    for (const ws of this.ctx.getWebSockets()) this.close(ws, 1008, "room_forgotten");
    await this.ctx.storage.deleteAll();
    await this.ctx.storage.deleteAlarm();
  }

  async snapshot(): Promise<{ hostOnline: boolean; clientOnline: boolean; entitled: boolean; blocked: boolean; liveCredentials: number; leaseEndsAt: number | null }> {
    const state = this.state();
    return {
      hostOnline: Boolean(this.peer("host")),
      clientOnline: Boolean(this.peer("client")),
      entitled: state.entitlement_id !== null,
      blocked: state.blocked === 1,
      liveCredentials: this.ctx.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM credentials").one().n,
      leaseEndsAt: state.lease_ends_at,
    };
  }
}
