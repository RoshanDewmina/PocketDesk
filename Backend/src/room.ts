import { GuestService, GUEST_FEATURE, type GuestOwner } from "./guest";
import { DurableObject } from "cloudflare:workers";
import { endRoomActivities } from "./activity";
import { isPublicEnvironment, loadConfig, type Config } from "./config";
import { accessEndMs, claimDeviceRoom, entitlementForDevice, hasAccess, restoreDeviceRoom, roomStatus, touchRoom } from "./entitlement/store";
import { environmentLetter, verifyEntitlementToken } from "./entitlement/token";
import { fingerprint, log, logError } from "./log";
import { incrementDaily } from "./metrics";
import { forgetPushRoom } from "./push";
import {
  AUTH_TIMEOUT_MS, DEVICES_FEATURE, MESSAGES_PER_SECOND, OUTBOUND_BYTES_PER_SECOND, REMOTE_FEATURE, RENEWAL_FEATURE, ROUTE_FEATURE, iceWithinClientLimits,
  parseAuthenticatedFrame, parseJsonFrame, parseRegister, type ErrorCode, type IceServer, type PeerRole, type RegisterMessage,
} from "./protocol";
import { WindowCounter, addressKey, allowStrict, withTimeout } from "./ratelimit";
import { turnProviderFromEnv, type TurnProvider } from "./turn";
import { randomHex, secureEqual, sha256Hex } from "./util";

type Attachment = {
  role?: PeerRole;
  guest?: boolean;
  guestAware?: boolean;
  guestOrigin?: string;
  authenticated: boolean;
  pending: boolean;
  connectedAt: number;
  ip?: string;
  renewable: boolean;
  remoteAware: boolean;
  routeAware?: boolean;
  entitled: boolean;
  /** The Mac received relay servers for the current phone; reset with `servers: []` when that phone leaves. */
  servedRelay?: boolean;
  entitlementId?: string;
  deviceId?: string;
  entitlementUntil?: number;
  issuedAt?: number;
  /** Last frame from this authenticated peer (registration counts). */
  lastSeenAt?: number;
  /** Host-authorized admission hashes, persisted by WebSocket hibernation; never sent to a client. */
  clientTokenHashes?: string[];
  /** The admitted client's individual token hash, so stale reconnect cannot evict another device. */
  clientTokenHash?: string;
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
  route_epoch: string | null;
  route_revision: number;
  route_expires_at: number | null;
};

type Entitlement = { entitled: boolean; entitlementId?: string; deviceId?: string; until?: number };

const ROOM_ISSUES_PER_MINUTE = 6;
const MAX_LIVE_SETS = 8;
const MIN_RENEW_AFTER_MS = 5000;
const RENEW_RETRY_MS = 30_000;
const IDLE_DELETE_MS = 30 * 24 * 60 * 60 * 1000;
const STORAGE_TIMEOUT_MS = 3000;
const ENTITLEMENT_RECHECK_MS = 5 * 60 * 1000;
/** Cloudflare's revoke endpoint can answer 404 for a credential issued moments ago; inside this window a 404 is retried. */
const REVOKE_NOT_FOUND_GRACE_MS = 30_000;
const REVOKE_BACKOFF_BASE_MS = 2000;
const REVOKE_BACKOFF_MAX_MS = 60_000;

const revokeBackoffMs = (attempts: number) => {
  const base = Math.min(REVOKE_BACKOFF_MAX_MS, REVOKE_BACKOFF_BASE_MS * 2 ** Math.min(attempts, 6));
  return Math.floor(base * (0.75 + Math.random() * 0.5));
};

class IssuanceRateLimited extends Error {}

/** A registration that did not ask for remote access (Couch mode) must stay on the proven local route. */
export function unentitledRelayPass(config: { allowUnentitledRelay: boolean; devRelayRooms: Set<string> },
  room: string | undefined, remoteAware: boolean): boolean {
  if (config.allowUnentitledRelay) return true;
  return remoteAware && room !== undefined && config.devRelayRooms.has(room);
}

export class RoomDO extends DurableObject<Env> {
  /** A pairing hash survives transient host disconnect so the phone can opt out while offline. */
  async authenticatePush(room: string, clientToken: string): Promise<boolean> {
    return this.authenticatePushHash(room, await sha256Hex(clientToken));
  }

  /** Compare a registry row with the room's current phone without exposing its pairing token. */
  async authenticatePushHash(room: string, clientHash: string): Promise<boolean> {
    const state = this.state();
    if ((state.room !== null && state.room !== room) || state.blocked !== 0) return false;
    const stored = this.ctx.storage.sql.exec<{ client_hash: string }>(
      "SELECT client_hash FROM push_pairing WHERE id=1 AND room=?", room,
    ).toArray()[0];
    return Boolean(stored && await secureEqual(clientHash, stored.client_hash));
  }

  /** Only the current route epoch may acquire an ActivityKit push address. */
  async authenticateActivity(room: string, clientToken: string, routeEpoch: string): Promise<boolean> {
    if (!(await this.authenticatePush(room, clientToken))) return false;
    try {
      const route = this.ctx.storage.sql.exec<{ route_epoch: string | null; route_expires_at: number | null; lease_ends_at: number | null }>(
        "SELECT route_epoch, route_expires_at, lease_ends_at FROM room WHERE id=1",
      ).one();
      const now = Date.now();
      return route.route_epoch === routeEpoch && route.route_expires_at !== null && route.route_expires_at > now &&
        route.lease_ends_at !== null && route.lease_ends_at > now;
    } catch {
      // Older room objects have no route epoch and cannot register ActivityKit pushes.
      return false;
    }
  }
  private readonly config: Config;
  private readonly provider: TurnProvider | undefined;
  private guestService: GuestService | undefined;
  private readonly guestBudgets = new WeakMap<WebSocket, WindowCounter>();
  private readonly messageCounters = new WeakMap<WebSocket, WindowCounter>();
  private readonly byteCounters = new WeakMap<WebSocket, WindowCounter>();
  private readonly issueCounter = new WindowCounter(ROOM_ISSUES_PER_MINUTE, 60_000);
  private readonly renewalPending = new WeakSet<WebSocket>();
  private activityEndDrain: Promise<void> | undefined;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.config = loadConfig(env);
    this.provider = turnProviderFromEnv(env);
    // Guest grants are transient: a cold/hibernated instance cannot recover recipient authority.
    for (const guest of ctx.getWebSockets("guest")) this.close(guest, 1008, "fresh_guest_approval_required");
    ctx.blockConcurrencyWhile(async () => {
      this.ensureSchema();
      const host = this.peer("host"), epoch = this.state().route_epoch;
      if (host && epoch && this.attachment(host).guestAware) {
        // Browser cooperation cannot retire direct RTC. Notify only the current authenticated owner.
        try { host.send(JSON.stringify({ type: "guest", version: 1, guest: { operation: "serviceReset", code: epoch, nonce: randomHex() } })); } catch {}
      }
      const retired = this.ctx.storage.sql.exec<{ username: string }>("SELECT username FROM credentials WHERE role LIKE 'guest:%' AND revoke_pending = 0").toArray();
      this.revokeUsernames(retired.map(row => row.username));
      if (retired.length) await this.scheduleAlarm();
    });
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
        recheck_at INTEGER,
        route_epoch TEXT,
        route_revision INTEGER NOT NULL DEFAULT 0,
        route_expires_at INTEGER
      );
      INSERT OR IGNORE INTO room (id) VALUES (1);
      CREATE TABLE IF NOT EXISTS credentials (
        username TEXT PRIMARY KEY,
        role TEXT NOT NULL,
        issued_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        revoke_pending INTEGER NOT NULL DEFAULT 0,
        revoke_attempts INTEGER NOT NULL DEFAULT 0,
        next_revoke_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS push_pairing (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        room TEXT NOT NULL,
        client_hash TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS activity_ends (
        epoch TEXT PRIMARY KEY, room TEXT NOT NULL, reason TEXT NOT NULL,
        next_attempt INTEGER NOT NULL, ended_at INTEGER NOT NULL
      );
    `);
    // Existing Durable Objects have the v1 table. Additive migration leaves pairings intact.
    const columns = new Set(this.ctx.storage.sql.exec<{ name: string }>("PRAGMA table_info(room)").toArray().map(row => row.name));
    if (!columns.has("route_epoch")) this.ctx.storage.sql.exec("ALTER TABLE room ADD COLUMN route_epoch TEXT");
    if (!columns.has("route_revision")) this.ctx.storage.sql.exec("ALTER TABLE room ADD COLUMN route_revision INTEGER NOT NULL DEFAULT 0");
    if (!columns.has("route_expires_at")) this.ctx.storage.sql.exec("ALTER TABLE room ADD COLUMN route_expires_at INTEGER");
  }

  /** Removes room data. Pending TURN usernames survive until revocation is confirmed or their TTL expires. */
  private async wipe(): Promise<void> {
    const blocked = this.state().blocked;
    // Offline phones must still be able to opt out or remove a push address. Only explicit
    // forget/block/credential rotation may discard the pairing hash.
    const hasPushPairing = this.ctx.storage.sql.exec("SELECT room FROM push_pairing LIMIT 1").toArray().length > 0;
    if (hasPushPairing || this.pendingRevocations().length > 0 || this.ctx.storage.sql.exec("SELECT epoch FROM activity_ends LIMIT 1").toArray().length > 0) {
      this.ctx.storage.sql.exec("DELETE FROM credentials WHERE revoke_pending = 0");
      this.ctx.storage.sql.exec("DELETE FROM room");
      this.ctx.storage.sql.exec("INSERT INTO room (id, blocked) VALUES (1, ?)", blocked);
      return;
    }
    await this.ctx.storage.deleteAll();
    await this.ctx.storage.deleteAlarm();
    this.ensureSchema();
    if (blocked) this.update({ blocked: 1 });
  }

  private state(): RoomState {
    return this.ctx.storage.sql.exec<RoomState>(
      "SELECT room, client_token_hash, lease_ends_at, blocked, entitlement_id, entitled_device, last_activity, ice_host, ice_client, last_keepalive, recheck_at, route_epoch, route_revision, route_expires_at FROM room WHERE id = 1",
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
    return this.ctx.getWebSockets().filter(ws => ws.readyState === WebSocket.OPEN && !this.attachment(ws).guest);
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
    this.sendText(ws, this.rememberIce(role, servers));
  }

  /** A keepalive must repeat the servers the peer holds now, never ones a renewal already replaced. */
  private rememberIce(role: PeerRole, servers: IceServer[]): string {
    const message = JSON.stringify({ type: "ice", servers, ...(this.config.testForceRelay ? { policy: "relay" } : {}) });
    this.update(role === "host" ? { ice_host: message } : { ice_client: message });
    return message;
  }

  /**
   * Frees `role` for `ws`, whose registration already proved that role's credentials. A phone that changed
   * networks leaves a socket the edge still reports open; once that peer has sent nothing for
   * `replaceQuietMs` it is dropped exactly as if it had closed. A live loser is told `replaced` (apps treat an
   * unknown service error as final), so two live copies of one pairing cannot keep evicting each other.
   */
  private takeSlot(role: PeerRole, ws: WebSocket, now: number): boolean {
    if (!this.slotTaken(role, ws)) return true;
    const incumbent = this.peer(role);
    if (this.config.replaceQuietMs === 0 || !incumbent || incumbent === ws) return false;
    const pendingOther = this.openSockets().some(other => other !== ws && other !== incumbent &&
      this.attachment(other).role === role && this.attachment(other).pending);
    const seen = this.attachment(incumbent);
    const quietMs = now - (seen.lastSeenAt ?? seen.connectedAt);
    if (pendingOther || quietMs < this.config.replaceQuietMs) return false;
    log("stale_peer_replaced", { room: fingerprint(this.state().room ?? undefined), role, quietMs });
    this.error(incumbent, "replaced");
    return !this.slotTaken(role, ws);
  }

  /** Server-originated policy only; it is never accepted as a peer frame or relayed. */
  private publishRoute(access: "local" | "remote", expiresAt: number): void {
    const state = this.state();
    if (!state.room || !state.route_epoch || !Number.isSafeInteger(expiresAt) || expiresAt <= Date.now()) return;
    const revision = state.route_revision + 1;
    this.update({ route_revision: revision, route_expires_at: expiresAt });
    const frame = { type: "route", version: 1, room: state.room, epoch: state.route_epoch,
      revision, access, expiresAt };
    for (const role of ["host", "client"] as const) {
      const ws = this.peer(role);
      if (ws && this.attachment(ws).routeAware) this.send(ws, frame);
    }
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
    const guestDeadline = this.guestService?.nearestDeadline;
    if (guestDeadline !== undefined) next = Math.min(next ?? Infinity, guestDeadline);
    for (const ws of this.ctx.getWebSockets("guest")) {
      if (ws.readyState === WebSocket.OPEN && !this.guestService?.owns(ws)) next = Math.min(next ?? Infinity, this.attachment(ws).connectedAt + AUTH_TIMEOUT_MS);
    }
    const state = this.state();
    if (state.lease_ends_at && this.peer("host")) next = Math.min(next ?? Infinity, state.lease_ends_at);
    if (state.route_expires_at && this.peer("client")) next = Math.min(next ?? Infinity, state.route_expires_at);
    if (state.recheck_at && state.entitlement_id) next = Math.min(next ?? Infinity, state.recheck_at);
    if (this.config.keepaliveMs > 0 && authenticatedOpen) {
      next = Math.min(next ?? Infinity, Math.max(state.last_keepalive, state.last_activity) + this.config.keepaliveMs);
    }
    const nextRevoke = this.ctx.storage.sql.exec<{ at: number | null }>("SELECT MIN(next_revoke_at) AS at FROM credentials WHERE revoke_pending = 1").one().at;
    if (nextRevoke !== null) next = Math.min(next ?? Infinity, nextRevoke);
    const nextActivity = this.ctx.storage.sql.exec<{ at: number | null }>("SELECT MIN(next_attempt) AS at FROM activity_ends").one().at;
    if (nextActivity !== null) next = Math.min(next ?? Infinity, nextActivity);
    if (next === undefined && this.openSockets().length === 0 && state.room !== null) next = now + IDLE_DELETE_MS;
    if (next === undefined) {
      await this.ctx.storage.deleteAlarm();
    } else {
      await this.ctx.storage.setAlarm(Math.max(now + 1, next));
    }
  }

  override async alarm(): Promise<void> {
    const now = Date.now();
    await this.guestService?.audit();
    for (const ws of this.ctx.getWebSockets("guest")) {
      if (!this.guestService?.owns(ws) && this.attachment(ws).connectedAt + AUTH_TIMEOUT_MS <= now) this.close(ws, 1008, "authentication_timeout");
    }
    for (const ws of this.openSockets()) {
      const attachment = this.attachment(ws);
      if (!attachment.authenticated && !attachment.pending && attachment.connectedAt + AUTH_TIMEOUT_MS <= now) {
        this.error(ws, "authentication_timeout");
      }
    }
    let state = this.state();
    const host = this.peer("host");
    if (host && this.peer("client") && state.route_expires_at !== null && state.route_expires_at <= now) {
      this.terminate("route_expired");
      state = this.state();
    } else if (host && state.lease_ends_at !== null && state.lease_ends_at <= now) {
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
    await this.drainActivityEnds().catch(error => logError("activity_end_queue_failed", error));
    if (this.openSockets().length === 0 && state.last_activity + IDLE_DELETE_MS <= now) {
      this.revokeAll();
      await this.wipe();
      await this.scheduleAlarm();
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
    const originalHost = this.peer("host");
    const originalClient = this.peer("client");
    const stillCurrent = (): boolean => {
      const latest = this.state();
      return this.peer("host") === originalHost && this.peer("client") === originalClient &&
        latest.room === state.room && latest.route_epoch === state.route_epoch &&
        latest.route_revision === state.route_revision &&
        latest.entitlement_id === state.entitlement_id && latest.entitled_device === state.entitled_device;
    };
    try {
      const row = await withTimeout(entitlementForDevice(this.env.DB, state.entitlement_id, state.entitled_device), STORAGE_TIMEOUT_MS, "entitlement recheck");
      if (!stillCurrent()) return;
      if (!row || !hasAccess(row, now, this.config.oneTimeProducts) || row.device_room !== state.room) {
        log("entitlement_lapsed_live", { room: fingerprint(state.room ?? undefined) });
        this.terminate("entitlement_revoked");
      }
    } catch (error) {
      if (!stillCurrent()) return;
      logError("entitlement_recheck_failed", error);
      // Once the paid policy is in use, an unverifiable renewal cannot keep internet access alive.
      if (this.peer("client") && this.state().route_expires_at !== null) this.terminate("entitlement_unavailable");
    }
  }

  // ---- credentials ----------------------------------------------------------------------------

  private rememberIssued(role: PeerRole | `guest:${string}`, servers: IceServer[], now: number): void {
    for (const server of servers) {
      if (!server.username) continue;
      this.ctx.storage.sql.exec(
        "INSERT OR REPLACE INTO credentials (username, role, issued_at, expires_at, revoke_pending, revoke_attempts, next_revoke_at) VALUES (?, ?, ?, ?, 0, 0, NULL)",
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

  /** Marks credentials for revocation and makes the first attempt; anything not settled is retried from the alarm until it expires. */
  private revokeUsernames(usernames: string[]): void {
    if (usernames.length === 0) return;
    const now = Date.now();
    const placeholders = usernames.map(() => "?").join(",");
    this.ctx.storage.sql.exec(`DELETE FROM credentials WHERE username IN (${placeholders}) AND expires_at <= ?`, ...usernames, now);
    this.ctx.storage.sql.exec(
      `UPDATE credentials SET revoke_pending = 1, revoke_attempts = 0, next_revoke_at = ? WHERE username IN (${placeholders}) AND revoke_pending = 0`,
      now, ...usernames,
    );
    const live = this.ctx.storage.sql.exec<{ username: string }>(`SELECT username FROM credentials WHERE username IN (${placeholders}) AND revoke_pending = 1`, ...usernames)
      .toArray().map(row => row.username);
    this.attemptRevocation(live);
  }

  /**
   * One provider round for these credentials. `confirmed` deletes the row; `not_found` is trusted only once the
   * credential is older than the propagation window (Cloudflare answers 404 for a moment after issuance); anything
   * else is rescheduled with exponential backoff and jitter. The row's next attempt time is pushed out while the
   * call is in flight so the alarm cannot start a second round for the same username.
   */
  private attemptRevocation(usernames: string[]): void {
    if (usernames.length === 0) return;
    const placeholders = usernames.map(() => "?").join(",");
    if (!this.provider) {
      this.ctx.storage.sql.exec(`DELETE FROM credentials WHERE username IN (${placeholders})`, ...usernames);
      return;
    }
    const provider = this.provider;
    const startedAt = Date.now();
    this.ctx.storage.sql.exec(`UPDATE credentials SET next_revoke_at = ? WHERE username IN (${placeholders})`, startedAt + REVOKE_BACKOFF_MAX_MS, ...usernames);
    this.ctx.waitUntil((async () => {
      let outcomes: Awaited<ReturnType<TurnProvider["revoke"]>>;
      try {
        outcomes = await provider.revoke(usernames);
      } catch (error) {
        logError("turn_revoke_failed", error, { count: usernames.length });
        outcomes = usernames.map(username => ({ username, status: "failed" as const }));
      }
      const now = Date.now();
      let rescheduled = 0;
      for (const outcome of outcomes) {
        const row = this.ctx.storage.sql.exec<{ issued_at: number; revoke_attempts: number }>(
          "SELECT issued_at, revoke_attempts FROM credentials WHERE username = ? AND revoke_pending = 1", outcome.username,
        ).toArray()[0];
        if (!row) continue;
        const settled = outcome.status === "confirmed" ||
          (outcome.status === "not_found" && now - row.issued_at >= REVOKE_NOT_FOUND_GRACE_MS);
        if (settled) {
          this.ctx.storage.sql.exec("DELETE FROM credentials WHERE username = ?", outcome.username);
          if (outcome.status === "not_found") log("turn_revoke_not_found_after_window", { ageMs: now - row.issued_at });
          continue;
        }
        // Backoff grows with the attempts already made: 1.5–2.5 s after the first, doubling to at most 60 s.
        this.ctx.storage.sql.exec(
          "UPDATE credentials SET revoke_attempts = ?, next_revoke_at = ? WHERE username = ?",
          row.revoke_attempts + 1, now + revokeBackoffMs(row.revoke_attempts), outcome.username,
        );
        rescheduled += 1;
      }
      if (rescheduled > 0) {
        log("turn_revoke_retry_scheduled", { count: rescheduled });
        await this.scheduleAlarm();
      }
    })());
  }

  /** Retries revocations whose backoff has elapsed; expired credentials need no revocation. */
  private retryRevocations(now: number): void {
    this.ctx.storage.sql.exec("DELETE FROM credentials WHERE revoke_pending = 1 AND expires_at <= ?", now);
    const due = this.ctx.storage.sql.exec<{ username: string }>(
      "SELECT username FROM credentials WHERE revoke_pending = 1 AND next_revoke_at <= ?", now,
    ).toArray().map(row => row.username);
    this.attemptRevocation(due);
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

  private async issueServers(role: PeerRole | `guest:${string}`, entitlementId: string | undefined): Promise<IceServer[]> {
    const servers: IceServer[] = this.config.stunUrls.length ? [{ urls: [...this.config.stunUrls] }] : [];
    if (!this.provider) return servers;
    const now = Date.now();
    if (!this.issueCounter.hit(now) || !(await allowStrict(this.env.RL_TURN, "turn", "RL_TURN"))) throw new IssuanceRateLimited();
    if (entitlementId && !(await allowStrict(this.env.RL_TURN_ENTITLEMENT, entitlementId, "RL_TURN_ENTITLEMENT"))) throw new IssuanceRateLimited();
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
  private async checkEntitlement(token: string | undefined, remoteAware: boolean): Promise<Entitlement> {
    if (!token) return this.unentitledRelayAllowed(remoteAware) ? { entitled: true } : { entitled: false };
    const now = Date.now();
    const payload = await verifyEntitlementToken(this.env.ENTITLEMENT_TOKEN_KEY, token, now, this.config.environmentName);
    if (!payload) return { entitled: false };
    try {
      const row = await withTimeout(entitlementForDevice(this.env.DB, payload.s, payload.d), STORAGE_TIMEOUT_MS, "entitlement lookup");
      if (!row || !hasAccess(row, now, this.config.oneTimeProducts) || environmentLetter(row.environment) !== payload.n) return { entitled: false };
      const until = Math.min(payload.x * 1000, accessEndMs(row));
      return { entitled: true, entitlementId: payload.s, deviceId: payload.d, until };
    } catch (error) {
      logError("entitlement_lookup_failed", error, { entitlement: fingerprint(payload.s) });
      return { entitled: false };
    }
  }

  private unentitledRelayAllowed(remoteAware: boolean): boolean {
    const room = this.state().room ?? undefined;
    if (!unentitledRelayPass(this.config, room, remoteAware)) return false;
    if (!this.config.allowUnentitledRelay && room !== undefined) log("dev_relay_pass_used", { room: fingerprint(room) });
    return true;
  }

  /** Fresh authorization is required before minting replacement TURN credentials. */
  private async stillEntitled(attachment: Attachment, now: number): Promise<"valid" | "invalid" | "unavailable"> {
    if (!attachment.entitled) return "invalid";
    if (attachment.entitlementUntil !== undefined && attachment.entitlementUntil <= now) return "invalid";
    const state = this.state();
    const entitlementId = attachment.entitlementId ?? state.entitlement_id;
    const deviceId = attachment.deviceId ?? state.entitled_device;
    if (!entitlementId || !deviceId) {
      // The dev pass belongs to the admitted phone, never the socket asking to renew.
      const phone = attachment.role === "host" ? this.peer("client") : undefined;
      const admitted = phone ? this.attachment(phone) : undefined;
      const passAware = attachment.role === "host"
        ? admitted?.entitled === true && admitted.remoteAware
        : attachment.role === "client" && attachment.remoteAware;
      return this.unentitledRelayAllowed(passAware) ? "valid" : "invalid";
    }
    try {
      const row = await withTimeout(entitlementForDevice(this.env.DB, entitlementId, deviceId), STORAGE_TIMEOUT_MS, "entitlement lookup");
      return row !== null && hasAccess(row, now, this.config.oneTimeProducts) && row.device_room === state.room ? "valid" : "invalid";
    } catch (error) {
      logError("entitlement_lookup_failed", error, { entitlement: fingerprint(entitlementId) });
      return "unavailable";
    }
  }

  // ---- WebSocket lifecycle ----------------------------------------------------------------------

  private async paidGuestOwner(): Promise<GuestOwner | undefined> {
    const host = this.peer("host"), client = this.peer("client"), state = this.state(), now = Date.now();
    if (!host || !client || !this.attachment(host).guestAware || !this.attachment(client).entitled ||
        state.blocked || !state.entitlement_id || !state.entitled_device || !state.route_epoch ||
        !state.route_expires_at || state.route_expires_at <= now || !state.lease_ends_at || state.lease_ends_at <= now) return;
    // No devRelayRooms, legacy private route, owner self-report or local-only purchase exemption.
    let row;
    try { row = await withTimeout(entitlementForDevice(this.env.DB, state.entitlement_id, state.entitled_device), STORAGE_TIMEOUT_MS, "guest paid admission"); }
    catch { return; } // Unknown paid authority closes guests; it never grants a fallback.
    const current = this.state(), at = Date.now();
    if (this.peer("host") !== host || this.peer("client") !== client || !row || !hasAccess(row, at, this.config.oneTimeProducts) || row.device_room !== state.room ||
        current.blocked || current.route_epoch !== state.route_epoch || current.route_revision !== state.route_revision ||
        current.entitlement_id !== state.entitlement_id || current.entitled_device !== state.entitled_device ||
        !current.route_expires_at || current.route_expires_at <= at || !current.lease_ends_at || current.lease_ends_at <= at ||
        !this.attachment(client).entitled || (this.attachment(client).entitlementUntil ?? 0) <= at) return;
    return { socket: host, client, epoch: current.route_epoch, expiresAt: Math.min(current.route_expires_at, current.lease_ends_at, this.attachment(client).entitlementUntil!) };
  }
  private guests(): GuestService {
    if (!this.guestService) this.guestService = new GuestService({
      now: () => Date.now(), owner: () => this.paidGuestOwner(),
      sendOwner: (owner, guest) => { try { (owner.socket as WebSocket).send(JSON.stringify({ type: "guest", version: 1, guest })); } catch {} },
      sendGuest: (socket, value) => { try { (socket as WebSocket).send(JSON.stringify(value)); } catch {} },
      closeGuest: (socket, code) => this.close(socket as WebSocket, 1008, code),
      issue: async (owner, grantID) => {
        const current = await this.paidGuestOwner();
        if (!current || current.socket !== owner.socket || current.client !== owner.client || current.epoch !== owner.epoch) throw new Error("guest authority expired");
        return this.issueServers(`guest:${grantID}`, this.state().entitlement_id ?? undefined);
      },
      revoke: servers => { this.revokeUsernames(servers.flatMap(s => s.username ? [s.username] : [])); this.ctx.waitUntil(this.scheduleAlarm()); },
    });
    return this.guestService;
  }
  private async guestMessage(ws: WebSocket, msg: Record<string, unknown>): Promise<void> {
    let budget = this.guestBudgets.get(ws);
    if (!budget) { budget = new WindowCounter(256 * 1024, 1000); this.guestBudgets.set(ws, budget); }
    if (!budget.hit(Date.now(), JSON.stringify(msg).length)) { this.guests().close(ws); this.close(ws, 1008, "guest_busy"); return; }
    if (msg.type === "guestRequest" && msg.version === 1 && msg.origin === this.attachment(ws).guestOrigin && msg.room === this.state().room) await this.guests().request(ws, msg);
    else if (msg.type === "guest" && msg.version === 1 && typeof msg.guest === "object") await this.guests().guestMessage(ws, msg.guest);
    else { this.guests().close(ws); this.close(ws, 1008, "guest_denied"); }
    await this.scheduleAlarm();
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/guest-connect" && request.headers.get("upgrade") === "websocket") {
      const pair = new WebSocketPair(); const [client, server] = Object.values(pair) as [WebSocket, WebSocket];
      this.ctx.acceptWebSocket(server, ["guest"]);
      this.save(server, { guest: true, guestOrigin: request.headers.get("x-farside-origin") ?? "", authenticated: false, pending: false, connectedAt: Date.now(), renewable: false, remoteAware: false, entitled: false });
      await this.scheduleAlarm(); return new Response(null, { status: 101, webSocket: client });
    }
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
    if (attachment.guest) { await this.guestMessage(ws, msg); return; }
    if (attachment.authenticated) {
      attachment.lastSeenAt = now;
      this.save(ws, attachment);
    }
    if (msg.type === "guest") {
      if (attachment.authenticated && attachment.role === "host" && attachment.guestAware && msg.version === 1) await this.guests().ownerMessage(ws, msg.guest);
      await this.scheduleAlarm(); return; // Guests never occupy/evict a native owner slot.
    }
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
    if (this.attachment(ws).guest) { this.guestService?.close(ws); await this.scheduleAlarm(); return; }
    this.close(ws, code === 1005 || code === 1006 ? 1000 : code, reason);
    this.dropPeer(ws);
    await this.scheduleAlarm();
  }

  override async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    if (this.attachment(ws).guest) { this.guestService?.close(ws); this.close(ws, 1011, "guest_error"); await this.scheduleAlarm(); return; }
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
    this.guestService?.endAll("owner_session_ended");
    this.queueActivityEnd(attachment.role === "host" ? "macStopped" : "user");
    this.revokeRole(attachment.role);
    if (attachment.role === "host") {
      this.update({ client_token_hash: null, lease_ends_at: null, entitlement_id: null, entitled_device: null, recheck_at: null, ice_host: null, ice_client: null, route_epoch: null, route_expires_at: null });
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
    this.update({ entitlement_id: null, entitled_device: null, recheck_at: null, ice_client: null, route_expires_at: null });
  }

  /** The lease ended: the host goes with `room_lifetime_reached` and its client with `host_disconnected`, as before. */
  private expireRoom(host: WebSocket): void {
    log("room_lease_expired", { room: fingerprint(this.state().room ?? undefined) });
    this.guestService?.endAll("owner_session_expired");
    this.queueActivityEnd("timeout");
    const client = this.peer("client");
    this.revokeAll();
    this.update({ client_token_hash: null, lease_ends_at: null, entitlement_id: null, entitled_device: null, recheck_at: null, ice_host: null, ice_client: null, route_epoch: null, route_expires_at: null });
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
    const routeAware = msg.features.has(ROUTE_FEATURE);
    if (isPublicEnvironment(this.config.environmentName) && !routeAware) {
      this.error(ws, "upgrade_required"); return;
    }

    if (msg.role === "host") {
      // Authenticate before revealing anything about the room, including whether a host is present.
      if (!msg.clientTokenHash || !(await secureEqual(await sha256Hex(msg.token), room))) { this.error(ws, "unauthorized"); return; }
      if (state.blocked) { this.error(ws, "room_not_approved"); return; }
      if (!this.takeSlot("host", ws, now)) { this.error(ws, "already_connected"); return; }
      if (!state.room) {
        // A brand-new room: bound how many rooms one address can create, closing bare so the app simply retries later.
        if (!(await allowStrict(this.env.RL_ROOM_CREATE, addressKey(attachment.ip), "RL_ROOM_CREATE"))) {
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
          this.close(ws, 1013, "room_status_unavailable");
          return;
        }
      }
      if (ws.readyState !== WebSocket.OPEN) return;
      if (this.slotTaken("host", ws)) { this.error(ws, "already_connected"); return; }
      const previousPush = this.ctx.storage.sql.exec<{ client_hash: string }>(
        "SELECT client_hash FROM push_pairing WHERE id=1 AND room=?", room,
      ).toArray()[0];
      if (previousPush && previousPush.client_hash !== msg.clientTokenHash) {
        try {
          await this.drainActivityEnds();
          if (this.ctx.storage.sql.exec("SELECT epoch FROM activity_ends LIMIT 1").toArray().length) throw new Error("activity_end_pending");
          await forgetPushRoom(this.env.DB, room);
        }
        catch {
          this.close(ws, 1013, "push_cleanup_unavailable");
          return;
        }
      }
      if (ws.readyState !== WebSocket.OPEN || this.slotTaken("host", ws)) return;
      this.ctx.storage.sql.exec(
        "INSERT INTO push_pairing (id,room,client_hash) VALUES (1,?,?) ON CONFLICT(id) DO UPDATE SET room=excluded.room, client_hash=excluded.client_hash",
        room, msg.clientTokenHash,
      );
      const leaseEndsAt = now + this.config.leaseMs;
      this.update({ room, client_token_hash: msg.clientTokenHash, lease_ends_at: leaseEndsAt, entitlement_id: null, entitled_device: null, recheck_at: null, last_activity: now,
        route_epoch: randomHex(16), route_revision: 0, route_expires_at: null });
      const next: Attachment = { ...attachment, role: "host", authenticated: true, pending: false, renewable, remoteAware, routeAware, guestAware: msg.features.has(GUEST_FEATURE), entitled: false, servedRelay: false, lastSeenAt: now,
        clientTokenHashes: msg.clientTokenHashes ?? [msg.clientTokenHash] };
      this.save(ws, next);
      this.send(ws, {
        type: "registered",
        role: "host",
        ...(msg.features.has(GUEST_FEATURE) || msg.features.has(DEVICES_FEATURE) ? {
          features: [GUEST_FEATURE, DEVICES_FEATURE].filter(feature => msg.features.has(feature)),
        } : {}),
        ...(renewable ? { renew: this.renewalOffer(next, leaseEndsAt, now) } : {}),
        ...(remoteAware ? { access: "local" } : {}),
      });
      this.sendIce(ws, "host", []);
      this.ctx.waitUntil(touchRoom(this.env.DB, room, now).catch(error => logError("room_touch_failed", error, { room: fingerprint(room) })));
      log("host_registered", { room: fingerprint(room), renewable });
      this.ctx.waitUntil(incrementDaily(this.env, "host_registered", now));
      await this.scheduleAlarm();
      return;
    }

    const host = this.peer("host");
    const clientTokenHash = state.client_token_hash;
    const presentedHash = await sha256Hex(msg.token);
    const trustedHashes = host ? this.attachment(host).clientTokenHashes ?? (clientTokenHash ? [clientTokenHash] : []) : [];
    const matches = await Promise.all(trustedHashes.map(hash => secureEqual(presentedHash, hash)));
    if (!host || !clientTokenHash || !matches.some(Boolean)) {
      this.error(ws, "host_unavailable_or_unauthorized");
      return;
    }
    if (isPublicEnvironment(this.config.environmentName) && !this.attachment(host).routeAware) {
      this.error(ws, "upgrade_required"); return;
    }
    if (this.peer("host") !== host || this.state().client_token_hash !== clientTokenHash) {
      this.error(ws, "host_unavailable_or_unauthorized"); return;
    }
    const incumbent = this.peer("client");
    // A different trusted device never takes over an active controller, even if its socket is quiet.
    // Same-device recovery keeps the existing opt-in stale-socket policy.
    if (incumbent && (this.attachment(incumbent).clientTokenHash ?? clientTokenHash) !== presentedHash) {
      this.error(ws, "already_connected"); return;
    }
    if (!this.takeSlot("client", ws, now)) { this.error(ws, "already_connected"); return; }

    let entitlement = await this.checkEntitlement(msg.entitlement, remoteAware);
    if (entitlement.entitled && entitlement.entitlementId && entitlement.deviceId) {
      // Mark this pending socket before crossing into D1. A forget/revoke push can then close it
      // even while TURN issuance or the ownership claim is in flight.
      this.save(ws, { ...this.attachment(ws), entitlementId: entitlement.entitlementId, deviceId: entitlement.deviceId });
      try {
        const claim = await withTimeout(
          claimDeviceRoom(this.env.DB, entitlement.entitlementId, entitlement.deviceId, room, now),
          STORAGE_TIMEOUT_MS, "room ownership claim",
        );
        if (!claim.claimed) {
          entitlement = { entitled: false };
        } else if (claim.previous && claim.previous !== room) {
          try {
            const rooms = this.env.ROOM as unknown as DurableObjectNamespace<RoomDO>;
            await withTimeout(rooms.get(rooms.idFromName(claim.previous)).revokeEntitlement(entitlement.entitlementId, entitlement.deviceId),
              STORAGE_TIMEOUT_MS, "previous room revoke");
          } catch (error) {
            await restoreDeviceRoom(this.env.DB, entitlement.entitlementId, entitlement.deviceId, room, claim.previous);
            throw error;
          }
        }
      } catch (error) {
        logError("device_room_claim_failed", error, { room: fingerprint(room) });
        this.close(ws, 1013, "busy");
        return;
      }
    }
    if (remoteAware && !entitlement.entitled) this.error(ws, "entitlement_required", false);
    if (ws.readyState !== WebSocket.OPEN) return;

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
    let authorized = true;
    if (entitlement.entitled && entitlement.entitlementId && entitlement.deviceId) {
      try {
        const at = Date.now();
        const row = await withTimeout(entitlementForDevice(this.env.DB, entitlement.entitlementId, entitlement.deviceId),
          STORAGE_TIMEOUT_MS, "entitlement before delivery");
        authorized = row !== null && hasAccess(row, at, this.config.oneTimeProducts) && row.device_room === room &&
          (entitlement.until ?? 0) > at;
      } catch (error) {
        logError("entitlement_before_delivery_failed", error, { room: fingerprint(room) });
        authorized = false;
      }
    }
    if (!authorized) {
      this.revokeUsernames([...clientServers, ...(hostServers ?? [])].flatMap(server => server.username ? [server.username] : []));
      clientServers = [];
      hostServers = undefined;
      entitlement = { entitled: false };
      if (remoteAware && ws.readyState === WebSocket.OPEN) this.error(ws, "entitlement_required", false);
    }
    const sameHost = ws.readyState === WebSocket.OPEN && this.peer("host") === host &&
      this.state().client_token_hash === clientTokenHash && !this.slotTaken("client", ws);
    if (!sameHost) {
      this.revokeRole("client");
      if (hostServers) this.revokeRole("host");
      if (ws.readyState === WebSocket.OPEN) this.error(ws, "host_unavailable_or_unauthorized");
      return;
    }

    const issuedAt = Date.now();
    const leaseEndsAt = this.state().lease_ends_at ?? issuedAt + this.config.leaseMs;
    const next: Attachment = {
      ...attachment, role: "client", authenticated: true, pending: false, renewable, remoteAware, routeAware,
      clientTokenHash: presentedHash,
      entitled: entitlement.entitled, entitlementId: entitlement.entitlementId, deviceId: entitlement.deviceId,
      entitlementUntil: entitlement.until, issuedAt: entitlement.entitled ? issuedAt : undefined, lastSeenAt: issuedAt,
    };
    this.save(ws, next);
    this.update({
      entitlement_id: entitlement.entitlementId ?? null,
      entitled_device: entitlement.deviceId ?? null,
      recheck_at: entitlement.entitlementId ? issuedAt + ENTITLEMENT_RECHECK_MS : null,
      last_activity: issuedAt,
      // A room can admit another phone without reconnecting its host. Each admission is a new
      // session boundary, so a late Activity registration for the previous phone cannot revive.
      route_epoch: randomHex(16),
      route_revision: 0,
      route_expires_at: null,
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
    if (routeAware && this.attachment(host).routeAware) {
      this.publishRoute(entitlement.entitled ? "remote" : "local",
        Math.min(leaseEndsAt, entitlement.entitled ? entitlement.until ?? leaseEndsAt : leaseEndsAt));
    }
    this.send(host, { type: "peer", online: true });
    this.send(ws, { type: "peer", online: true });
    log("client_registered", { room: fingerprint(room), entitled: entitlement.entitled, renewable });
    this.ctx.waitUntil(incrementDaily(this.env, entitlement.entitled ? "signaling_ready_anywhere" : "signaling_ready_free", issuedAt));
    await this.scheduleAlarm();
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
    if (state.route_expires_at !== null && now >= state.route_expires_at) { this.terminate("route_expired"); return; }
    if (this.renewalPending.has(ws)) {
      this.send(ws, { type: "renewed", leaseSeconds: this.config.leaseMs / 1000, renewAfterSeconds: MIN_RENEW_AFTER_MS / 1000, code: "renewal_pending" });
      return;
    }
    // A paid route cannot silently outlive the verified transaction/grace deadline.
    const originalClient = this.peer("client");
    let routeAuthorization: "valid" | "invalid" | "unavailable" = "valid";
    if (state.route_expires_at !== null && state.entitlement_id && originalClient) {
      routeAuthorization = await this.stillEntitled(this.attachment(originalClient), now);
    }
    // An entitlement lookup yields to other room events. Never let a stale renewal publish a
    // policy for a replacement host, phone, or route epoch.
    const latest = this.state();
    if (ws.readyState !== WebSocket.OPEN || this.peer(attachment.role) !== ws || this.peer("client") !== originalClient ||
        latest.route_epoch !== state.route_epoch || latest.route_revision !== state.route_revision ||
        latest.entitlement_id !== state.entitlement_id || latest.lease_ends_at !== state.lease_ends_at) return;
    if (routeAuthorization !== "valid") {
      this.terminate(routeAuthorization === "invalid" ? "entitlement_revoked" : "entitlement_unavailable");
      return;
    }
    const leaseEndsAt = now + this.config.leaseMs;
    this.update({ lease_ends_at: leaseEndsAt, last_activity: now });
    if (this.peer("client") && state.route_expires_at !== null) {
      const client = this.attachment(this.peer("client")!);
      this.publishRoute(client.entitled ? "remote" : "local",
        Math.min(leaseEndsAt, client.entitled ? client.entitlementUntil ?? leaseEndsAt : leaseEndsAt));
    }
    const renewalRevision = this.state().route_revision;
    const currentForRenewal = (): boolean => {
      const current = this.state();
      return ws.readyState === WebSocket.OPEN && this.peer(attachment.role!) === ws &&
        this.peer("client") === originalClient && current.lease_ends_at === leaseEndsAt &&
        current.route_epoch === state.route_epoch && current.route_revision === renewalRevision &&
        current.entitlement_id === state.entitlement_id;
    };
    await this.scheduleAlarm();

    let servers: IceServer[] | undefined;
    let code: string | undefined;
    const refreshDue = this.provider && attachment.entitled && attachment.issuedAt !== undefined &&
      now - attachment.issuedAt >= Math.floor(this.config.turnTtlSeconds * 1000 / 3);
    if (refreshDue) {
      this.renewalPending.add(ws);
      try {
        const authorization = await this.stillEntitled(attachment, now);
        if (!currentForRenewal()) return;
        if (state.route_expires_at !== null && authorization !== "valid") {
          this.terminate(authorization === "invalid" ? "entitlement_revoked" : "entitlement_unavailable");
          return;
        }
        if (authorization === "invalid") code = "entitlement_required";
        else if (authorization === "unavailable") code = "relay_unavailable";
        else servers = await this.issueServers(attachment.role, attachment.entitlementId ?? state.entitlement_id ?? undefined);
      } catch (error) {
        code = error instanceof IssuanceRateLimited ? "rate_limited" : "relay_unavailable";
      } finally {
        this.renewalPending.delete(ws);
      }
      if (servers) {
        if (!currentForRenewal()) {
          this.revokeUsernames(servers.flatMap(s => s.username ? [s.username] : []));
          return;
        }
        const refreshed = { ...this.attachment(ws), issuedAt: Date.now() };
        this.save(ws, refreshed);
        attachment = refreshed;
        this.rememberIce(attachment.role!, servers);
        log("relay_refreshed", { room: fingerprint(state.room ?? undefined), role: attachment.role });
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

  /** Persist before clearing the session, so a D1 outage cannot lose suspended-phone termination. */
  private queueActivityEnd(reason: "macStopped" | "timeout" | "user" | "error"): void {
    const state = this.state();
    if (!state.room || !state.route_epoch || state.route_expires_at === null) return;
    const endedAt = Date.now();
    this.ctx.storage.sql.exec("INSERT OR IGNORE INTO activity_ends (epoch,room,reason,next_attempt,ended_at) VALUES (?,?,?,?,?)",
      state.route_epoch, state.room, reason, endedAt, endedAt);
    this.ctx.waitUntil(this.drainActivityEnds().catch(error => logError("activity_end_queue_failed", error))
      .finally(() => this.scheduleAlarm()));
  }

  private drainActivityEnds(): Promise<void> {
    if (this.activityEndDrain) return this.activityEndDrain;
    const work = this.deliverActivityEnds();
    this.activityEndDrain = work;
    void work.finally(() => { if (this.activityEndDrain === work) this.activityEndDrain = undefined; }).catch(() => {});
    return work;
  }

  private async deliverActivityEnds(): Promise<void> {
    const rows = this.ctx.storage.sql.exec<{ epoch: string; room: string; reason: "macStopped" | "timeout" | "user" | "error"; ended_at: number }>(
      "SELECT epoch,room,reason,ended_at FROM activity_ends WHERE next_attempt<=?", Date.now()).toArray();
    for (const row of rows) {
      // D1 owns bounded APNs retries once this call has durably marked the end event.
      this.ctx.storage.sql.exec("UPDATE activity_ends SET next_attempt=? WHERE epoch=?", Date.now() + 60_000, row.epoch);
      await endRoomActivities(this.env, row.room, row.epoch, row.reason, row.ended_at);
      this.ctx.storage.sql.exec("DELETE FROM activity_ends WHERE epoch=?", row.epoch);
    }
  }

  private terminate(reason: string): void {
    log("room_terminated", { room: fingerprint(this.state().room ?? undefined), reason });
    this.guestService?.endAll(reason);
    this.queueActivityEnd(reason === "route_expired" ? "timeout" : "error");
    this.revokeAll();
    for (const ws of this.ctx.getWebSockets()) {
      this.detach(ws);
      this.close(ws, 1008, reason);
    }
    this.update({ client_token_hash: null, lease_ends_at: null, entitlement_id: null, entitled_device: null, recheck_at: null, ice_host: null, ice_client: null, route_epoch: null, route_expires_at: null });
  }

  async revokeEntitlement(entitlementId: string, deviceId: string, onlyIfInactive = false): Promise<boolean> {
    if (onlyIfInactive) {
      // A later paid purchase can commit after the refund handler wrote D1 but before its push.
      // The push must not terminate the replacement room using that newer entitlement.
      const row = await withTimeout(entitlementForDevice(this.env.DB, entitlementId, deviceId),
        STORAGE_TIMEOUT_MS, "revocation freshness check");
      if (row && hasAccess(row, Date.now(), this.config.oneTimeProducts) && row.device_room === this.state().room) return false;
    }
    const state = this.state();
    if (state.entitlement_id !== entitlementId || state.entitled_device !== deviceId) {
      let pendingClosed = false;
      for (const ws of this.openSockets()) {
        const attachment = this.attachment(ws);
        if (!attachment.pending || attachment.entitlementId !== entitlementId || attachment.deviceId !== deviceId) continue;
        this.detach(ws);
        this.close(ws, 1008, "entitlement_revoked");
        pendingClosed = true;
      }
      if (pendingClosed) await this.scheduleAlarm();
      return pendingClosed;
    }
    log("entitlement_revoked_live", { room: fingerprint(state.room ?? undefined) });
    this.terminate("entitlement_revoked");
    await this.scheduleAlarm();
    return true;
  }

  async block(): Promise<void> {
    const room = this.state().room ?? this.ctx.storage.sql.exec<{ room: string }>("SELECT room FROM push_pairing WHERE id=1").toArray()[0]?.room;
    this.update({ blocked: 1 });
    this.ctx.storage.sql.exec("DELETE FROM push_pairing");
    this.terminate("room_not_approved");
    // Preserve unmarked activity addresses while a queued end is waiting on D1.
    await this.drainActivityEnds();
    if (this.ctx.storage.sql.exec("SELECT epoch FROM activity_ends LIMIT 1").toArray().length) throw new Error("activity_end_pending");
    if (room) await forgetPushRoom(this.env.DB, room);
    await this.scheduleAlarm();
  }

  async unblock(): Promise<void> {
    this.update({ blocked: 0 });
  }

  async forget(): Promise<void> {
    this.queueActivityEnd("user");
    // Admission must stop before the first await: a suspended Activity registration must not
    // arrive after its old epoch's end queue has already been drained.
    this.update({ route_epoch: null, route_expires_at: null, lease_ends_at: null });
    this.revokeAll();
    for (const ws of this.ctx.getWebSockets()) {
      this.detach(ws);
      this.close(ws, 1008, "room_forgotten");
    }
    await this.drainActivityEnds();
    if (this.ctx.storage.sql.exec("SELECT epoch FROM activity_ends LIMIT 1").toArray().length) throw new Error("activity_end_pending");
    const room = this.state().room ?? this.ctx.storage.sql.exec<{ room: string }>("SELECT room FROM push_pairing WHERE id=1").toArray()[0]?.room;
    if (room) await forgetPushRoom(this.env.DB, room);
    this.ctx.storage.sql.exec("DELETE FROM push_pairing");
    await this.wipe();
    await this.scheduleAlarm();
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
