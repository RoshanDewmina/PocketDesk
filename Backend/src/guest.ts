import type { IceServer } from "./protocol";
import { base64Decode, base64Encode, isRecord, randomHex, sha256Hex } from "./util";

export const GUEST_FEATURE = "guest-v1";
export const GUEST_MAXIMUM = 2;
export const guestToken = (v: unknown): v is string => typeof v === "string" && /^[a-f0-9]{64}$/.test(v);
export const guestEpoch = (v: unknown): v is string => typeof v === "string" && /^[1-9][0-9]{0,19}$/.test(v) && BigInt(v) <= 18446744073709551615n;
export function guestOrigin(v: unknown): v is string {
  if (typeof v !== "string") return false;
  try { const u = new URL(v); return u.origin === v && (u.protocol === "https:" || (u.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(u.hostname))); } catch { return false; }
}
export function guestKey(v: unknown): v is string {
  if (typeof v !== "string") return false;
  try { const b = base64Decode(v); return b.length === 65 && b[0] === 4 && base64Encode(b) === v; } catch { return false; }
}
export function guestCanonical(fields: string[]): Uint8Array {
  const parts = ["Farside/guest/1", ...fields].map(v => new TextEncoder().encode(v));
  const out = new Uint8Array(parts.reduce((n, p) => n + 4 + p.length, 0));
  let offset = 0;
  for (const p of parts) { new DataView(out.buffer).setUint32(offset, p.length); out.set(p, offset + 4); offset += 4 + p.length; }
  return out;
}
export async function guestVerify(fields: string[], signature: unknown, publicKey: string): Promise<boolean> {
  if (!guestKey(publicKey) || typeof signature !== "string" || fields.length > 32 || fields.some(v => v.length > 4096)) return false;
  try {
    const sig = base64Decode(signature); if (sig.length !== 64 || base64Encode(sig) !== signature) return false;
    const key = await crypto.subtle.importKey("raw", base64Decode(publicKey) as BufferSource, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, sig as BufferSource, guestCanonical(fields) as BufferSource);
  } catch { return false; }
}
export type GuestGrant = {
  version: number; hostID: string; grantID: string; ownerSessionID: string; scopeEpoch: string; geometryEpoch: string;
  scopeKind: string; mode: string; requestID: string; recipientPublicKey: string; recipientAgreementKey: string;
  hostAgreementKey: string; recipientNonce: string; hostNonce: string; origin: string; issuedAt: number; expiresAt: number; ticketHash: string;
};
export function grantFields(g: GuestGrant): string[] {
  return ["grant", g.origin, g.hostID, g.grantID, g.ownerSessionID, g.scopeEpoch, g.geometryEpoch, g.scopeKind, g.mode,
    g.requestID, g.recipientPublicKey, g.recipientAgreementKey, g.hostAgreementKey, g.recipientNonce, g.hostNonce,
    String(g.issuedAt), String(g.expiresAt), g.ticketHash];
}
export function validGuestGrant(value: unknown, now: number): value is GuestGrant {
  if (!isRecord(value)) return false;
  const g = value as unknown as GuestGrant;
  return Object.keys(value).sort().join() === ["version", "hostID", "grantID", "ownerSessionID", "scopeEpoch", "geometryEpoch", "scopeKind", "mode", "requestID", "recipientPublicKey", "recipientAgreementKey", "hostAgreementKey", "recipientNonce", "hostNonce", "origin", "issuedAt", "expiresAt", "ticketHash"].sort().join() &&
    guestOrigin(g.origin) && g.version === 1 && g.mode === "view" && [g.hostID, g.grantID, g.ownerSessionID, g.requestID, g.recipientNonce, g.hostNonce, g.ticketHash].every(guestToken) &&
    guestEpoch(g.scopeEpoch) && guestEpoch(g.geometryEpoch) && ["display", "application", "window"].includes(g.scopeKind) &&
    [g.recipientPublicKey, g.recipientAgreementKey, g.hostAgreementKey].every(guestKey) &&
    Number.isSafeInteger(g.issuedAt) && Number.isSafeInteger(g.expiresAt) && g.issuedAt > 0 && g.issuedAt <= now && g.expiresAt > now && g.expiresAt - g.issuedAt <= 600_000;
}
export type GuestOwner = { socket: object; client: object; epoch: string; expiresAt: number };
export type GuestSocket = object;
type Invite = { grantID: string; inviteHash: string; publicKey: string; hostID: string; ownerSessionID: string;
  scopeEpoch: string; geometryEpoch: string; scopeKind: string; origin: string; expiresAt: number };
type Request = { socket: GuestSocket; requestID: string; publicKey: string; agreementKey: string; nonce: string; signature: string };
type Record = { owner: GuestOwner; invite: Invite; pending?: Request; state: "invited" | "pending" | "approved" | "issuing" | "active";
  grant?: GuestGrant; ticket?: string; sessionID?: string; deadline?: number; servers?: IceServer[]; lastGuestSequence: bigint; lastHostSequence: bigint };
export type GuestDependencies = {
  now(): number;
  owner(): Promise<GuestOwner | undefined>; // Real adapter must recheck D1 + exact current sockets/epoch around await.
  sendOwner(owner: GuestOwner, guest: unknown): void;
  sendGuest(socket: GuestSocket, message: unknown): void;
  closeGuest(socket: GuestSocket, reason: string): void;
  issue(owner: GuestOwner, grantID: string): Promise<IceServer[]>;
  revoke(servers: IceServer[]): void;
};

/** Transient child grants only. A DO restart must close retained guest sockets, never restore authority. */
export class GuestService {
  private readonly grants = new Map<string, Record>();
  private readonly sockets = new Map<GuestSocket, Record>();
  private readonly requesting = new Set<GuestSocket>();
  constructor(private readonly deps: GuestDependencies) {}
  private same(a: GuestOwner | undefined, b: GuestOwner): boolean { return !!a && a.socket === b.socket && a.client === b.client && a.epoch === b.epoch && a.expiresAt > this.deps.now(); }
  private async current(record: Record): Promise<boolean> { return this.grants.get(record.invite.grantID) === record && this.same(await this.deps.owner(), record.owner) && this.grants.get(record.invite.grantID) === record && (record.deadline ?? record.invite.expiresAt) > this.deps.now(); }
  private end(record: Record, code: string): void {
    if (this.grants.get(record.invite.grantID) !== record) return;
    this.grants.delete(record.invite.grantID);
    if (record.pending) { this.sockets.delete(record.pending.socket); this.deps.closeGuest(record.pending.socket, code); }
    if (record.servers) this.deps.revoke(record.servers);
    this.deps.sendOwner(record.owner, { operation: "ended", grantID: record.invite.grantID, sessionID: record.sessionID, code });
  }
  endAll(code: string): void { for (const r of [...this.grants.values()]) this.end(r, code); }
  close(socket: GuestSocket): void { const r = this.sockets.get(socket); if (r) this.end(r, "guest_closed"); this.requesting.delete(socket); }
  async audit(): Promise<void> { for (const r of [...this.grants.values()]) if (!(await this.current(r))) this.end(r, "authority_expired"); }
  owns(socket: GuestSocket): boolean { return this.sockets.has(socket) || this.requesting.has(socket); }
  get nearestDeadline(): number | undefined { const values = [...this.grants.values()].map(r => r.deadline ?? r.invite.expiresAt); return values.length ? Math.min(...values) : undefined; }
  private reject(socket: GuestSocket): void { this.deps.closeGuest(socket, "guest_denied"); }

  async ownerMessage(socket: object, message: unknown): Promise<boolean> {
    if (!isRecord(message) || typeof message.operation !== "string" || JSON.stringify(message).length > 8192 && message.operation !== "signal") return false;
    const owner = await this.deps.owner();
    if (!owner || owner.socket !== socket || owner.expiresAt <= this.deps.now()) return false;
    if (message.operation === "invite") {
      const now = this.deps.now(), g = message;
      if (this.grants.size >= 4 || [...this.grants.values()].filter(r => r.state === "invited" || r.state === "pending").length >= 2 ||
          ![g.grantID, g.inviteHash, g.hostID, g.ownerSessionID].every(guestToken) || !guestKey(g.publicKey) ||
          !guestEpoch(g.scopeEpoch) || !guestEpoch(g.geometryEpoch) || !["display", "application", "window"].includes(String(g.scopeKind)) ||
          !Number.isSafeInteger(g.expiresAt) || Number(g.expiresAt) <= now || Number(g.expiresAt) - now > 120_000 || !guestOrigin(g.origin) || g.mode !== "view") return false;
      if (this.grants.has(g.grantID as string)) return false;
      const invite = { ...g, expiresAt: Math.min(Number(g.expiresAt), owner.expiresAt) } as unknown as Invite;
      this.grants.set(invite.grantID, { owner, invite, state: "invited", lastGuestSequence: 0n, lastHostSequence: 0n });
      this.deps.sendOwner(owner, { operation: "created", grantID: invite.grantID, expiresAt: invite.expiresAt }); return true;
    }
    const r = guestToken(message.grantID) ? this.grants.get(message.grantID) : undefined;
    if (!r || !this.same(owner, r.owner) || !(await this.current(r))) return false;
    if (message.operation === "deny" && (!r.pending || message.requestID !== r.pending.requestID)) return false;
    if (message.operation === "revoke" || message.operation === "deny") { this.end(r, "owner_ended"); return true; }
    if (message.operation === "approve") {
      if (r.state !== "pending" || !r.pending || [...this.grants.values()].filter(x => ["approved", "issuing", "active"].includes(x.state)).length >= GUEST_MAXIMUM ||
          message.requestID !== r.pending.requestID || !validGuestGrant(message.grant, this.deps.now()) || !guestToken(message.ticket)) return false;
      const grant = message.grant;
      if (grant.grantID !== r.invite.grantID || grant.hostID !== r.invite.hostID || grant.ownerSessionID !== r.invite.ownerSessionID ||
          grant.scopeEpoch !== r.invite.scopeEpoch || grant.geometryEpoch !== r.invite.geometryEpoch || grant.scopeKind !== r.invite.scopeKind || grant.origin !== r.invite.origin ||
          grant.requestID !== r.pending.requestID || grant.recipientPublicKey !== r.pending.publicKey || grant.recipientAgreementKey !== r.pending.agreementKey ||
          grant.recipientNonce !== r.pending.nonce || grant.expiresAt > owner.expiresAt || !(await guestVerify(grantFields(grant), message.signature, r.invite.publicKey)) ||
          grant.ticketHash !== await sha256Hex(message.ticket) || !(await this.current(r)) || r.state !== "pending") return false;
      if ([...this.grants.values()].filter(x => ["approved", "issuing", "active"].includes(x.state)).length >= GUEST_MAXIMUM) return false;
      r.state = "approved"; r.grant = grant; r.ticket = message.ticket;
      r.sessionID = await sha256Hex(guestCanonical(grantFields(grant)));
      r.deadline = Math.min(this.deps.now() + 30_000, grant.expiresAt);
      if (!(await this.current(r))) { this.end(r, "authority_expired"); return false; }
      this.deps.sendGuest(r.pending.socket, { type: "guest", version: 1, guest: { operation: "approved", grant, signature: message.signature, ticket: r.ticket, sessionID: r.sessionID } });
      return true;
    }
    if (message.operation === "check") {
      if (Object.keys(message).sort().join() !== ["operation", "grantID", "sessionID", "nonce"].sort().join() ||
          r.state !== "active" || message.sessionID !== r.sessionID || !guestToken(message.nonce) || !r.grant) return false;
      // The current() await immediately above rechecks exact sockets/route and fresh paid D1 authority.
      this.deps.sendOwner(r.owner, { operation: "alive", grantID: r.invite.grantID, sessionID: r.sessionID,
        nonce: message.nonce, expiresAt: r.grant.expiresAt });
      return true;
    }
    if (message.operation === "signal") return this.signal(r, message, "host");
    return false;
  }
  async request(socket: GuestSocket, message: unknown): Promise<void> {
    if (this.requesting.has(socket) || this.sockets.has(socket) || !isRecord(message)) { this.reject(socket); return; }
    this.requesting.add(socket);
    try {
      const r = guestToken(message.grantID) ? this.grants.get(message.grantID) : undefined;
      if (!r || r.state !== "invited" || message.origin !== r.invite.origin || !guestToken(message.secret) || !guestKey(message.publicKey) || !guestKey(message.agreementKey) || !guestToken(message.nonce) ||
          await sha256Hex(message.secret) !== r.invite.inviteHash || !(await guestVerify(["request", r.invite.origin, String(message.room), r.invite.grantID, message.publicKey, message.agreementKey, message.nonce], message.signature, message.publicKey)) ||
          !(await this.current(r)) || r.state !== "invited" || !this.requesting.has(socket)) { this.reject(socket); return; }
      const pending: Request = { socket, requestID: randomHex(), publicKey: message.publicKey, agreementKey: message.agreementKey, nonce: message.nonce, signature: String(message.signature) };
      r.pending = pending; r.state = "pending"; this.sockets.set(socket, r);
      this.deps.sendOwner(r.owner, { operation: "pending", grantID: r.invite.grantID, requestID: pending.requestID, publicKey: pending.publicKey, agreementKey: pending.agreementKey, nonce: pending.nonce, signature: pending.signature });
    } finally { this.requesting.delete(socket); }
  }
  async guestMessage(socket: GuestSocket, message: unknown): Promise<void> {
    const r = this.sockets.get(socket);
    if (!r || !isRecord(message) || !(await this.current(r))) { if (r) this.end(r, "authority_expired"); else this.reject(socket); return; }
    if (message.operation === "redeem") {
      if (r.state !== "approved" || !r.pending || !r.grant || message.ticket !== r.ticket || message.sessionID !== r.sessionID ||
          !(await guestVerify(["redeem", String(r.ticket), String(r.sessionID), r.grant.hostNonce], message.signature, r.pending.publicKey)) || !(await this.current(r)) || r.state !== "approved") { this.end(r, "guest_denied"); return; }
      // Consume before provider await; no renewal/replay can issue a second credential set.
      r.state = "issuing"; r.ticket = undefined;
      let servers: IceServer[];
      try { servers = await this.deps.issue(r.owner, r.invite.grantID); } catch { this.end(r, "relay_unavailable"); return; }
      if (!(await this.current(r)) || r.state !== "issuing" || !r.grant) { this.deps.revoke(servers); this.end(r, "authority_expired"); return; }
      r.servers = servers; r.state = "active"; r.deadline = r.grant.expiresAt;
      const ready = { operation: "ready", grantID: r.invite.grantID, sessionID: r.sessionID, servers, expiresAt: r.deadline };
      this.deps.sendOwner(r.owner, ready); this.deps.sendGuest(socket, { type: "guest", version: 1, guest: ready }); return;
    }
    if (message.operation === "signal" && await this.signal(r, message, "guest")) return;
    this.end(r, "guest_denied");
  }
  private async signal(r: Record, message: { [k: string]: unknown }, direction: "host" | "guest"): Promise<boolean> {
    if (r.state !== "active" || message.grantID !== r.invite.grantID || message.sessionID !== r.sessionID || !isRecord(message.envelope)) return false;
    const e = message.envelope;
    if (e.direction !== direction || typeof e.sequence !== "string" || !/^[1-9][0-9]{0,15}$/.test(e.sequence) || BigInt(e.sequence) > 9007199254740991n ||
        typeof e.payload !== "string" || e.payload.length > 174784 || !/^[A-Za-z0-9+/]+={0,2}$/.test(e.payload)) return false;
    const n = BigInt(e.sequence), last = direction === "host" ? r.lastHostSequence : r.lastGuestSequence;
    if (n <= last || !(await this.current(r))) return false;
    // Recheck after async owner proof; two concurrent packets cannot both reuse one sequence.
    if (n <= (direction === "host" ? r.lastHostSequence : r.lastGuestSequence)) return false;
    if (direction === "host") r.lastHostSequence = n; else r.lastGuestSequence = n;
    const payload = { operation: "signal", grantID: r.invite.grantID, sessionID: r.sessionID, envelope: e };
    if (direction === "host" && r.pending) this.deps.sendGuest(r.pending.socket, { type: "guest", version: 1, guest: payload }); else this.deps.sendOwner(r.owner, payload);
    return true;
  }
}
