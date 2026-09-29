import { HEX64, isRecord } from "./util";

export const PROTOCOL_VERSION = 1;
export const RENEWAL_FEATURE = "renew.1";
export const REMOTE_FEATURE = "remote.1";

export const MAX_FRAME_BYTES = 256 * 1024;
export const MAX_JSON_CHARS = 200 * 1024;
export const MAX_SIGNAL_PAYLOAD_CHARS = 180 * 1024;
export const MIN_SIGNAL_PAYLOAD_CHARS = 40;
export const MAX_ICE_SERVERS = 8;
export const MAX_ICE_URLS = 8;
export const MAX_ENTITLEMENT_TOKEN_CHARS = 512;
export const AUTH_TIMEOUT_MS = 5000;
export const MESSAGES_PER_SECOND = 100;
export const BACKPRESSURE_LIMIT_BYTES = 512 * 1024;

const featurePattern = /^[a-z0-9][a-z0-9._-]{0,31}$/;
const maxFeatures = 8;
const base64Pattern = /^[A-Za-z0-9+/]+={0,2}$/;

export type PeerRole = "host" | "client";

export type RegisterMessage = {
  role: PeerRole;
  room: string;
  token: string;
  clientTokenHash?: string;
  features: Set<string>;
  entitlement?: string;
};

export type ErrorCode =
  | "invalid_registration"
  | "unauthorized"
  | "already_connected"
  | "host_unavailable_or_unauthorized"
  | "room_not_approved"
  | "relay_unavailable"
  | "invalid_message"
  | "rate_limit"
  | "peer_unavailable"
  | "authentication_timeout"
  | "registration_pending"
  | "entitlement_required"
  | "busy";

export type ParsedFrame =
  | { kind: "register"; value: RegisterMessage }
  | { kind: "renew" }
  | { kind: "signal"; payload: string }
  | { kind: "invalid"; code: "invalid_message" | "invalid_registration" };

function parseFeatures(value: unknown): Set<string> | undefined {
  if (value === undefined) return new Set();
  if (!Array.isArray(value) || value.length > maxFeatures) return undefined;
  const features = new Set<string>();
  for (const item of value) {
    if (typeof item !== "string" || !featurePattern.test(item)) return undefined;
    features.add(item);
  }
  return features;
}

export function parseJsonFrame(raw: string | ArrayBuffer): Record<string, unknown> | undefined {
  if (typeof raw !== "string" || raw.length > MAX_JSON_CHARS) return undefined;
  try {
    const parsed: unknown = JSON.parse(raw);
    return isRecord(parsed) ? parsed : undefined;
  } catch {
    return undefined;
  }
}

export function parseRegister(msg: Record<string, unknown>): RegisterMessage | undefined {
  const features = parseFeatures(msg.features);
  if (msg.type !== "register" || msg.version !== PROTOCOL_VERSION || !features) return undefined;
  if (typeof msg.room !== "string" || !HEX64.test(msg.room)) return undefined;
  if (typeof msg.token !== "string" || !HEX64.test(msg.token)) return undefined;
  if (msg.role !== "host" && msg.role !== "client") return undefined;
  const result: RegisterMessage = { role: msg.role, room: msg.room, token: msg.token, features };
  if (msg.clientTokenHash !== undefined) {
    if (typeof msg.clientTokenHash !== "string" || !HEX64.test(msg.clientTokenHash)) return undefined;
    result.clientTokenHash = msg.clientTokenHash;
  }
  if (msg.entitlement !== undefined) {
    if (typeof msg.entitlement !== "string" || msg.entitlement.length === 0 || msg.entitlement.length > MAX_ENTITLEMENT_TOKEN_CHARS) return undefined;
    result.entitlement = msg.entitlement;
  }
  return result;
}

/** Frames from an authenticated peer: exactly `renew`, or `signal` with an opaque base64 payload. */
export function parseAuthenticatedFrame(msg: Record<string, unknown>): ParsedFrame {
  if (msg.type === "renew") {
    return Object.keys(msg).length === 1 ? { kind: "renew" } : { kind: "invalid", code: "invalid_message" };
  }
  if (msg.type === "signal" && typeof msg.payload === "string" &&
      msg.payload.length >= MIN_SIGNAL_PAYLOAD_CHARS && msg.payload.length <= MAX_SIGNAL_PAYLOAD_CHARS &&
      base64Pattern.test(msg.payload)) {
    return { kind: "signal", payload: msg.payload };
  }
  return { kind: "invalid", code: "invalid_message" };
}

export type IceServer = { urls: string[]; username?: string; credential?: string };

export const iceWithinClientLimits = (servers: IceServer[]) =>
  servers.length <= MAX_ICE_SERVERS && servers.every(server => server.urls.length <= MAX_ICE_URLS);
