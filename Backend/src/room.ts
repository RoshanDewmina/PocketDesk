import { DurableObject } from "cloudflare:workers";
import { loadConfig, type Config } from "./config";
import { entitlementForDevice, hasAccess, roomStatus, setDeviceRoom, touchRoom } from "./entitlement/store";
import { verifyEntitlementToken } from "./entitlement/token";
import { fingerprint, log, logError } from "./log";
import {
  AUTH_TIMEOUT_MS, MESSAGES_PER_SECOND, OUTBOUND_BYTES_PER_SECOND, REMOTE_FEATURE, RENEWAL_FEATURE, iceWithinClientLimits,
  parseAuthenticatedFrame, parseJsonFrame, parseRegister, type ErrorCode, type IceServer, type PeerRole, type RegisterMessage,
} from "./protocol";
import { WindowCounter, addressKey, allow, withTimeout } from "./ratelimit";
import { turnProviderFromEnv, type TurnProvider } from "./turn";
import { secureEqual, sha256Hex } from "./util";

type Attachment = {
  role?: PeerRole;
  authenticated: boolean;
  pending: boolean;
  connectedAt: number;
  ip?: string;
  renewable: boolean;
  remoteAware: boolean;
  entitled: boolean;
  /** The Mac received relay servers for the current phone; reset with `servers: []` when that phone leaves. */
  servedRelay?: boolean;
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
  entitled_device: string | null;
  last_activity: number;
  ice_host: string | null;
  ice_client: string | null;
  last_keepalive: number;
  recheck_at: number | null;
};

type Entitlement = { entitled: boolean; entitlementId?: string; deviceId?: string; until?: number };

const ROOM_ISSUES_PER_MINUTE = 6;
const MAX_LIVE_SETS = 8;
const MIN_RENEW_AFTER_MS = 5000;
const RENEW_RETRY_MS = 30_000;
const IDLE_DELETE_MS = 30 * 24 * 60 * 60 * 1000;
const STORAGE_TIMEOUT_MS = 3000;
const ENTITLEMENT_RECHECK_MS = 5 * 60 * 1000;
const REVOKE_RETRY_MS = 60_000;

class IssuanceRateLimited extends Error {}

export class RoomDO extends DurableObject<Env> {
  private readonly config: Config;
  private readonly provider: TurnProvider | undefined;
  private readonly messageCounters = new WeakMap<WebSocket, WindowCounter>();
  private readonly byteCounters = new WeakMap<WebSocket, WindowCounter>();
  private readonly issueCounter = new WindowCounter(ROOM_ISSUES_PER_MINUTE, 60_000);
  private readonly renewalPending = new WeakSet<WebSocket>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.config = loadConfig(env);
    this.provider = turnProviderFromEnv(env);
    ctx.blockConcurrencyWhile(async () => this.ensureSchema());
  }

  // ---- storage --------------------------------------------------------------------------------

  private ensureSchema(): void {
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS room (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        room TEXT,
        client_token_hash TEXT,
        lease_ends_at INTEGER,
        blocked INTEGER NOT NULL DEFAULT 0,
        entitlement_id TEXT,
        entitled_device TEXT,
        last_activity INTEGER NOT NULL DEFAULT 0,
        ice_host TEXT,
        ice_client TEXT,
        last_keepalive INTEGER NOT NULL DEFAULT 0,
        recheck_at INTEGER
      );
      INSERT OR IGNORE INTO room (id) VALUES (1);
      CREATE TABLE IF NOT EXISTS credentials (
        username TEXT PRIMARY KEY,
        role TEXT NOT NULL,
        issued_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        revoke_pending INTEGER NOT NULL DEFAULT 0,
        revoke_requested_at INTEGER
      );
    `);
  }

  /** Wipes everything this room stored (a block survives) and leaves the object usable for a later registration. */
  private async wipe(): Promise<void> {
    const blocked = this.state().blocked;
    await this.ctx.storage.deleteAll();
    await this.ctx.storage.deleteAlarm();
    this.ensureSchema();
    if (blocked) this.update({ blocked: 1 });
  }

  private state(): RoomState {
    return this.ctx.storage.sql.exec<RoomState>(
      "SELECT room, client_token_hash, lease_ends_at, blocked, entitlement_id, entitled_device, last_activity, ice_host, ice_client, last_keepalive, recheck_at FROM room WHERE id = 1",
    ).one();
  }

  private update(fields: Partial<RoomState>): void {
    const keys = Object.keys(fields) as (keyof RoomState)[];
    if (keys.length === 0) return;
    this.ctx.storage.sql.exec(
      `UPDATE room SET ${keys.map(key => `${key} = ?`).join(", ")} WHERE id = 1`,
      ...keys.map(key => fields[key] as string | number | null),
    );
  }

  // ---- sockets --------------------------------------------------------------------------------

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

  private openSockets(): WebSocket[] {
    return this.ctx.getWebSockets().filter(ws => ws.readyState === WebSocket.OPEN);
  }

  private peer(role: PeerRole): WebSocket | undefined {
    return this.openSockets().find(ws => {
      const attachment = this.attachment(ws);
      return attachment.authenticated && attachment.role === role;
    });
  }

  /** A role's slot is taken by an authenticated peer or by a registration still in flight. */
  private slotTaken(role: PeerRole, except: WebSocket): boolean {
    return this.openSockets().some(ws => {
      if (ws === except) return false;
      const attachment = this.attachment(ws);
      return attachment.role === role && (attachment.authenticated || attachment.pending);
    });
  }

  private sendText(ws: WebSocket, text: string): void {
    const now = Date.now();
    let budget = this.byteCounters.get(ws);
    if (!budget) {
      budget = new WindowCounter(OUTBOUND_BYTES_PER_SECOND, 1000);
      this.byteCounters.set(ws, budget);
    }
    if (!budget.hit(now, text.length)) {
      log("outbound_budget_exceeded", { room: fingerprint(this.state().room ?? undefined) });
      this.dropPeer(ws);
      this.close(ws, 1013, "busy");
      return;
    }
    try {
      ws.send(text);
    } catch (error) {
      logError("send_failed", error);
    }
  }

  private send(ws: WebSocket, value: unknown): void {
    this.sendText(ws, JSON.stringify(value));
  }

  /** Sends `ice` and remembers it verbatim, so a keepalive can repeat exactly what the peer already accepted. */
  private sendIce(ws: WebSocket, role: PeerRole, servers: IceServer[]): void {
    const message = JSON.stringify({ type: "ice", servers, ...(this.config.testForceRelay ? { policy: "relay" } : {}) });
    this.update(role === "host" ? { ice_host: message } : { ice_client: message });
    this.sendText(ws, message);
  }

  private close(ws: WebSocket, code: number, reason: string): void {
    try {
      ws.close(code, reason);
    } catch {
      // already closed
    }
  }

  /** Error frame, then close. An authenticated peer is dropped from the room first so its close event finds nothing to undo. */
  private error(ws: WebSocket, code: ErrorCode, close = true): void {
    if (close) this.dropPeer(ws);
    this.send(ws, { type: "error", code });
    if (close) this.close(ws, 1008, code);
  }

  // ---- alarm ----------------------------------------------------------------------------------

  private async scheduleAlarm(): Promise<void> {
    const now = Date.now();
    let next: number | undefined;
    let authenticatedOpen = false;
    for (const ws of this.openSockets()) {
      const attachment = this.attachment(ws);
      if (attachment.authenticated) authenticatedOpen = true;
      else if (!attachment.pending) next = Math.min(next ?? Infinity, attachment.connectedAt + AUTH_TIMEOUT_MS);
    }
    const state = this.state();
    if (state.lease_ends_at && this.peer("host")) next = Math.min(next ?? Infinity, state.lease_ends_at);
    if (state.recheck_at && state.entitlement_id) next = Math.min(next ?? Infinity, state.recheck_at);
    if (this.config.keepaliveMs > 0 && authenticatedOpen) {
      next = Math.min(next ?? Infinity, Math.max(state.last_keepalive, state.last_activity) + this.config.keepaliveMs);
    }
    const oldestPending = this.ctx.storage.sql.exec<{ at: number | null }>("SELECT MIN(revoke_requested_at) AS at FROM credentials WHERE revoke_pending = 1").one().at;
    if (oldestPending !== null) next = Math.min(next ?? Infinity, oldestPending + REVOKE_RETRY_MS);
    if (next === undefined && this.openSockets().length === 0) next = now + IDLE_DELETE_MS;
    if (next === undefined) {
      await this.ctx.storage.deleteAlarm();
    } else {
      await this.ctx.storage.setAlarm(Math.max(now + 1, next));
    }
  }

  override async alarm(): Promise<void> {
    const now = Date.now();
    for (const ws of this.openSockets()) {
      const attachment = this.attachment(ws);
      if (!attachment.authenticated && !attachment.pending && attachment.connectedAt + AUTH_TIMEOUT_MS <= now) {
        this.error(ws, "authentication_timeout");
      }
    }
    let state = this.state();
    const host = this.peer("host");
    if (host && state.lease_ends_at !== null && state.lease_ends_at <= now) {
      this.expireRoom(host);
      state = this.state();
    } else if (state.entitlement_id && state.recheck_at !== null && state.recheck_at <= now) {
      await this.recheckEntitlement(state, now);
      state = this.state();
    }
    if (this.config.keepaliveMs > 0 && Math.max(state.last_keepalive, state.last_activity) + this.config.keepaliveMs <= now) {
      this.keepalive(state, now);
    }
    this.retryRevocations(now);
    if (this.openSockets().length === 0 && state.last_activity + IDLE_DELETE_MS <= now) {
      this.revokeAll();
      await this.wipe();
      return;
    }
    await this.scheduleAlarm();
  }

  /** Repeats each authenticated peer's last `ice` message unchanged; the apps only store its contents. */
  private keepalive(state: RoomState, now: number): void {
    for (const ws of this.openSockets()) {
      const attachment = this.attachment(ws);
      if (!attachment.authenticated || !attachment.role) continue;
      const message = attachment.role === "host" ? state.ice_host : state.ice_client;
      if (message) this.sendText(ws, message);
    }
    this.update({ last_keepalive: now });
  }

  /** A live entitled room asks D1 every few minutes whether the subscription is still good, closing the refund race. */
  private async recheckEntitlement(state: RoomState, now: number): Promise<void> {
    this.update({ recheck_at: now + ENTITLEMENT_RECHECK_MS });
    if (!state.entitlement_id || !state.entitled_device) return;
    try {
      const row = await withTimeout(entitlementForDevice(this.env.DB, state.entitlement_id, state.entitled_device), STORAGE_TIMEOUT_MS, "entitlement recheck");
      if (!row || !hasAccess(row, now)) {
        log("entitlement_lapsed_live", { room: fingerprint(state.room ?? undefined) });
        this.terminate("entitlement_revoked");
      }
    } catch (error) {
      logError("entitlement_recheck_failed", error);
    }
  }

  // ---- credentials ----------------------------------------------------------------------------

  private rememberIssued(role: PeerRole, servers: IceServer[], now: number): void {
    for (const server of servers) {
      if (!server.username) continue;
      this.ctx.storage.sql.exec(
        "INSERT OR REPLACE INTO credentials (username, role, issued_at, expires_at, revoke_pending) VALUES (?, ?, ?, ?, 0)",
        server.username, role, now, now + this.config.turnTtlSeconds * 1000,
      );
    }
    const live = this.ctx.storage.sql.exec<{ username: string }>(
      "SELECT username FROM credentials WHERE role = ? AND revoke_pending = 0 ORDER BY issued_at DESC", role,
    ).toArray();
    const dropped = live.slice(MAX_LIVE_SETS).map(row => row.username);
    if (dropped.length) this.revokeUsernames(dropped);
  }

  private pendingRevocations(): string[] {
    return this.ctx.storage.sql.exec<{ username: string }>("SELECT username FROM credentials WHERE revoke_pending = 1").toArray().map(row => row.username);
  }

  /** Marks credentials for revocation and asks the provider; anything not confirmed is retried from the alarm until it expires. */
  private revokeUsernames(usernames: string[]): void {
    if (usernames.length === 0) return;
    const now = Date.now();
    const placeholders = usernames.map(() => "?").join(",");
    this.ctx.storage.sql.exec(`DELETE FROM credentials WHERE username IN (${placeholders}) AND expires_at <= ?`, ...usernames, now);
    this.ctx.storage.sql.exec(`UPDATE credentials SET revoke_pending = 1, revoke_requested_at = ? WHERE username IN (${placeholders})`, now, ...usernames);
    const live = this.ctx.storage.sql.exec<{ username: string }>(`SELECT username FROM credentials WHERE username IN (${placeholders})`, ...usernames)
      .toArray().map(row => row.username);
    if (!this.provider || live.length === 0) {
      if (live.length) this.ctx.storage.sql.exec(`DELETE FROM credentials WHERE username IN (${live.map(() => "?").join(",")})`, ...live);
      return;
    }
    const provider = this.provider;
    this.ctx.waitUntil((async () => {
      let unconfirmed: string[] = live;
      try {
        unconfirmed = await provider.revoke(live);
      } catch (error) {
        logError("turn_revoke_failed", error, { count: live.length });
      }
      const confirmed = live.filter(username => !unconfirmed.includes(username));
      if (confirmed.length) this.ctx.storage.sql.exec(`DELETE FROM credentials WHERE username IN (${confirmed.map(() => "?").join(",")})`, ...confirmed);
      if (unconfirmed.length) log("turn_revoke_retry_scheduled", { count: unconfirmed.length });
    })());
  }

  /** Retries revocations whose last attempt is old enough to have finished; expired credentials need no revocation. */
  private retryRevocations(now: number): void {
    this.ctx.storage.sql.exec("DELETE FROM credentials WHERE revoke_pending = 1 AND expires_at <= ?", now);
    const due = this.ctx.storage.sql.exec<{ username: string }>(
      "SELECT username FROM credentials WHERE revoke_pending = 1 AND revoke_requested_at <= ?", now - REVOKE_RETRY_MS / 2,
    ).toArray().map(row => row.username);
    if (due.length) this.revokeUsernames(due);
  }

  private revokeRole(role: PeerRole): void {
    const usernames = this.ctx.storage.sql.exec<{ username: string }>("SELECT username FROM credentials WHERE role = ? AND revoke_pending = 0", role)
      .toArray().map(row => row.username);
    this.revokeUsernames(usernames);
  }

  private revokeAll(): void {
    const usernames = this.ctx.storage.sql.exec<{ username: string }>("SELECT username FROM credentials WHERE revoke_pending = 0").toArray().map(row => row.username);
    this.revokeUsernames(usernames);
  }

  private async issueServers(role: PeerRole, entitlementId: string | undefined): Promise<IceServer[]> {
    const servers: IceServer[] = this.config.stunUrls.length ? [{ urls: [...this.config.stunUrls] }] : [];
    if (!this.provider) return servers;
    const now = Date.now();
    if (!this.issueCounter.hit(now) || !(await allow(this.env.RL_TURN, "turn", "RL_TURN"))) throw new IssuanceRateLimited();
    if (entitlementId && !(await allow(this.env.RL_TURN_ENTITLEMENT, entitlementId, "RL_TURN_ENTITLEMENT"))) throw new IssuanceRateLimited();
    const issued = await this.provider.issue();
    const combined = [...servers, ...issued];
    if (!iceWithinClientLimits(combined)) {
      this.rememberIssued(role, issued, now);
      this.revokeUsernames(issued.flatMap(server => server.username ? [server.username] : []));
      throw new Error("relay configuration exceeds client limits");
    }
    this.rememberIssued(role, issued, now);
    return combined;
  }

  /** Issues for both peers; if either issuance fails the other credential is revoked at once. */
  private async issueBoth(entitlementId: string | undefined): Promise<[IceServer[], IceServer[]]> {
    const results = await Promise.allSettled([this.issueServers("client", entitlementId), this.issueServers("host", entitlementId)]);
    const failure = results.find(result => result.status === "rejected") as PromiseRejectedResult | undefined;
    if (failure) {
      for (const result of results) {
        if (result.status === "fulfilled") this.revokeUsernames(result.value.flatMap(server => server.username ? [server.username] : []));
      }
      throw failure.reason;
    }
    return [(results[0] as PromiseFulfilledResult<IceServer[]>).value, (results[1] as PromiseFulfilledResult<IceServer[]>).value];
  }

  // ---- entitlement ----------------------------------------------------------------------------

  /**
   * A token proves nothing on its own: the (subscription, device) link must still exist and the subscription must
   * still have access. Storage trouble at registration means no relay (a token is at most 24 h old, so a short
   * outage costs at most a local-only session); an established session keeps its credentials through `stillEntitled`.
   */
  private async checkEntitlement(token: string | undefined): Promise<Entitlement> {
    if (!token) return this.config.allowUnentitledRelay ? { entitled: true } : { entitled: false };
    const now = Date.now();
    const payload = await verifyEntitlementToken(this.env.ENTITLEMENT_TOKEN_KEY, token, now, this.config.environmentName);
    if (!payload) return { entitled: false };
    try {
      const row = await withTimeout(entitlementForDevice(this.env.DB, payload.s, payload.d), STORAGE_TIMEOUT_MS, "entitlement lookup");
      if (!row || !hasAccess(row, now)) return { entitled: false };
      const until = Math.min(payload.x * 1000, Math.max(row.expires_at, row.grace_until ?? 0));
      return { entitled: true, entitlementId: payload.s, deviceId: payload.d, until };
    } catch (error) {
      logError("entitlement_lookup_failed", error, { entitlement: fingerprint(payload.s) });
      return { entitled: false };
    }
  }

  private async stillEntitled(attachment: Attachment, now: number): Promise<boolean> {
    if (!attachment.entitled) return false;
    if (attachment.entitlementUntil !== undefined && attachment.entitlementUntil <= now) return false;
    const state = this.state();
    const entitlementId = attachment.entitlementId ?? state.entitlement_id;
    const deviceId = attachment.deviceId ?? state.entitled_device;
    if (!entitlementId || !deviceId) return this.config.allowUnentitledRelay;
    try {
      const row = await withTimeout(entitlementForDevice(this.env.DB, entitlementId, deviceId), STORAGE_TIMEOUT_MS, "entitlement lookup");
      return row !== null && hasAccess(row, now);
    } catch (error) {
      logError("entitlement_lookup_failed", error, { entitlement: fingerprint(entitlementId) });
      return true;
    }
  }

  // ---- WebSocket lifecycle ----------------------------------------------------------------------

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname !== "/connect" || request.headers.get("upgrade") !== "websocket") return new Response("Not found", { status: 404 });
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair) as [WebSocket, WebSocket];
    this.ctx.acceptWebSocket(server);
    const ip = request.headers.get("x-farside-ip") ?? undefined;
    this.save(server, { authenticated: false, pending: false, connectedAt: Date.now(), ip, renewable: false, remoteAware: false, entitled: false });
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
    if (frame.kind !== "signal") { this.error(ws, "invalid_message"); return; }
    const other = this.peer(attachment.role === "host" ? "client" : "host");
    if (!other) { this.error(ws, "peer_unavailable", false); return; }
    this.send(other, { type: "signal", payload: frame.payload });
  }

  override async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    this.close(ws, code === 1005 || code === 1006 ? 1000 : code, reason);
    this.dropPeer(ws);
    await this.scheduleAlarm();
  }

  override async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    logError("socket_error", error);
    this.close(ws, 1011, "error");
    this.dropPeer(ws);
    await this.scheduleAlarm();
  }

  /** Forgets a peer before closing it, so its own close event cannot act on a room that has moved on. */
  private detach(ws: WebSocket): Attachment {
    const attachment = this.attachment(ws);
    this.save(ws, { ...attachment, authenticated: false, pending: false, role: undefined });
    return attachment;
  }

  /** Removes a peer from the room: revokes its credentials and tells or closes its counterpart. Idempotent. */
  private dropPeer(ws: WebSocket): void {
    const attachment = this.detach(ws);
    if (!attachment.authenticated || !attachment.role) return;
    this.revokeRole(attachment.role);
    if (attachment.role === "host") {
      this.update({ client_token_hash: null, lease_ends_at: null, entitlement_id: null, entitled_device: null, recheck_at: null, ice_host: null, ice_client: null });
      const client = this.peer("client");
      if (client) {
        this.detach(client);
        this.revokeRole("client");
        this.close(client, 1001, "host_disconnected");
      }
      return;
    }
    const host = this.peer("host");
    if (host) {
      // No session can use the Mac's relay credential without this phone; the next phone gets a fresh one.
      this.revokeRole("host");
      this.send(host, { type: "peer", online: false });
      const hostAttachment = this.attachment(host);
      if (hostAttachment.servedRelay) {
        this.save(host, { ...hostAttachment, servedRelay: false, entitled: false, issuedAt: undefined, entitlementUntil: undefined });
        this.sendIce(host, "host", []);
      }
    }
    this.update({ entitlement_id: null, entitled_device: null, recheck_at: null, ice_client: null });
  }

  /** The lease ended: the host goes with `room_lifetime_reached` and its client with `host_disconnected`, as before. */
  private expireRoom(host: WebSocket): void {
    const client = this.peer("client");
    this.revokeAll();
    this.update({ client_token_hash: null, lease_ends_at: null, entitlement_id: null, entitled_device: null, recheck_at: null, ice_host: null, ice_client: null });
    this.detach(host);
    this.close(host, 1001, "room_lifetime_reached");
    if (client) {
      this.detach(client);
      this.close(client, 1001, "host_disconnected");
    }
  }

  // ---- registration ---------------------------------------------------------------------------

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
      // Authenticate before revealing anything about the room, including whether a host is present.
      if (!msg.clientTokenHash || !(await secureEqual(await sha256Hex(msg.token), room))) { this.error(ws, "unauthorized"); return; }
      if (state.blocked) { this.error(ws, "room_not_approved"); return; }
      if (this.slotTaken("host", ws)) { this.error(ws, "already_connected"); return; }
      if (!state.room) {
        // A brand-new room: bound how many rooms one address can create, closing bare so the app simply retries later.
        if (!(await allow(this.env.RL_ROOM_CREATE, addressKey(attachment.ip), "RL_ROOM_CREATE"))) {
          log("room_create_rate_limited", { room: fingerprint(room) });
          this.close(ws, 1013, "rate_limited");
          return;
        }
        // Honour a block recorded in D1 before the object existed.
        try {
          if ((await withTimeout(roomStatus(this.env.DB, room), STORAGE_TIMEOUT_MS, "room status")) === "blocked") {
            this.update({ blocked: 1, room });
            this.error(ws, "room_not_approved");
            return;
          }
        } catch (error) {
          logError("room_status_lookup_failed", error, { room: fingerprint(room) });
        }
      }
      if (ws.readyState !== WebSocket.OPEN) return;
      if (this.slotTaken("host", ws)) { this.error(ws, "already_connected"); return; }
      const leaseEndsAt = now + this.config.leaseMs;
      this.update({ room, client_token_hash: msg.clientTokenHash, lease_ends_at: leaseEndsAt, entitlement_id: null, entitled_device: null, recheck_at: null, last_activity: now });
      const next: Attachment = { ...attachment, role: "host", authenticated: true, pending: false, renewable, remoteAware, entitled: false, servedRelay: false };
      this.save(ws, next);
      this.send(ws, {
        type: "registered",
        role: "host",
        ...(renewable ? { renew: this.renewalOffer(next, leaseEndsAt, now) } : {}),
        ...(remoteAware ? { access: "local" } : {}),
      });
      this.sendIce(ws, "host", []);
      this.ctx.waitUntil(touchRoom(this.env.DB, room, now).catch(error => logError("room_touch_failed", error, { room: fingerprint(room) })));
      log("host_registered", { room: fingerprint(room), renewable });
      await this.scheduleAlarm();
      return;
    }

    const host = this.peer("host");
    const clientTokenHash = state.client_token_hash;
    if (!host || !clientTokenHash || !(await secureEqual(await sha256Hex(msg.token), clientTokenHash))) {
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
        [clientServers, hostServers] = await this.issueBoth(entitlement.entitlementId);
      } catch (error) {
        if (ws.readyState === WebSocket.OPEN) this.error(ws, "relay_unavailable");
        log("relay_issue_failed", { room: fingerprint(room), reason: error instanceof IssuanceRateLimited ? "rate_limited" : "provider" });
        return;
      }
    }
    // The Mac must still be the one this phone authenticated against: same socket, same pairing.
    const sameHost = ws.readyState === WebSocket.OPEN && this.peer("host") === host && this.state().client_token_hash === clientTokenHash;
    if (!sameHost) {
      this.revokeRole("client");
      if (hostServers) this.revokeRole("host");
      if (ws.readyState === WebSocket.OPEN) this.error(ws, "host_unavailable_or_unauthorized");
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
    this.update({
      entitlement_id: entitlement.entitlementId ?? null,
      entitled_device: entitlement.deviceId ?? null,
      recheck_at: entitlement.entitlementId ? issuedAt + ENTITLEMENT_RECHECK_MS : null,
      last_activity: issuedAt,
    });
    if (hostServers) {
      const hostAttachment = this.attachment(host);
      this.save(host, { ...hostAttachment, entitled: true, servedRelay: true, issuedAt, entitlementUntil: entitlement.until });
      this.sendIce(host, "host", hostServers);
    }
    this.send(ws, {
      type: "registered",
      role: "client",
      ...(renewable ? { renew: this.renewalOffer(next, leaseEndsAt, issuedAt) } : {}),
      ...(remoteAware ? { access: entitlement.entitled ? "remote" : "local" } : {}),
    });
    this.sendIce(ws, "client", clientServers);
    this.send(host, { type: "peer", online: true });
    this.send(ws, { type: "peer", online: true });
    if (entitlement.entitled && entitlement.entitlementId && entitlement.deviceId) {
      this.ctx.waitUntil(this.recordLiveRoom(entitlement.entitlementId, entitlement.deviceId, room, issuedAt));
    }
    log("client_registered", { room: fingerprint(room), entitled: entitlement.entitled, renewable });
    await this.scheduleAlarm();
  }

  /** One live room per device: registering here ends the entitlement of the room this device used before. */
  private async recordLiveRoom(entitlementId: string, deviceId: string, room: string, now: number): Promise<void> {
    try {
      const previous = await setDeviceRoom(this.env.DB, entitlementId, deviceId, room, now);
      if (previous && previous !== room) {
        const rooms = this.env.ROOM as unknown as DurableObjectNamespace<RoomDO>;
        await rooms.get(rooms.idFromName(previous)).revokeEntitlement(entitlementId);
        log("previous_room_entitlement_ended", { room: fingerprint(previous) });
      }
    } catch (error) {
      logError("device_room_update_failed", error);
    }
  }

  // ---- renewal --------------------------------------------------------------------------------

  private async renew(ws: WebSocket, attachment: Attachment): Promise<void> {
    const now = Date.now();
    const state = this.state();
    const host = this.peer("host");
    if (!host || !attachment.role || (attachment.role === "client" && this.peer("client") !== ws) || (attachment.role === "host" && host !== ws)) {
      this.dropPeer(ws);
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
      this.renewalPending.add(ws);
      try {
        if (!(await this.stillEntitled(attachment, now))) code = "entitlement_required";
        else servers = await this.issueServers(attachment.role, attachment.entitlementId ?? state.entitlement_id ?? undefined);
      } catch (error) {
        code = error instanceof IssuanceRateLimited ? "rate_limited" : "relay_unavailable";
      } finally {
        this.renewalPending.delete(ws);
      }
      if (servers) {
        if (ws.readyState !== WebSocket.OPEN || this.state().lease_ends_at !== leaseEndsAt && this.peer(attachment.role) !== ws) {
          this.revokeUsernames(servers.flatMap(s => s.username ? [s.username] : []));
          return;
        }
        const refreshed = { ...this.attachment(ws), issuedAt: Date.now() };
        this.save(ws, refreshed);
        attachment = refreshed;
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

  // ---- operator / system RPC ------------------------------------------------------------------

  private terminate(reason: string): void {
    this.revokeAll();
    for (const ws of this.ctx.getWebSockets()) {
      this.detach(ws);
      this.close(ws, 1008, reason);
    }
    this.update({ client_token_hash: null, lease_ends_at: null, entitlement_id: null, entitled_device: null, recheck_at: null, ice_host: null, ice_client: null });
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
    for (const ws of this.ctx.getWebSockets()) {
      this.detach(ws);
      this.close(ws, 1008, "room_forgotten");
    }
    await this.wipe();
  }

  async snapshot(): Promise<{ hostOnline: boolean; clientOnline: boolean; entitled: boolean; blocked: boolean; liveCredentials: number; pendingRevocations: number; leaseEndsAt: number | null }> {
    const state = this.state();
    return {
      hostOnline: Boolean(this.peer("host")),
      clientOnline: Boolean(this.peer("client")),
      entitled: state.entitlement_id !== null,
      blocked: state.blocked === 1,
      liveCredentials: this.ctx.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM credentials WHERE revoke_pending = 0").one().n,
      pendingRevocations: this.pendingRevocations().length,
      leaseEndsAt: state.lease_ends_at,
    };
  }
}
