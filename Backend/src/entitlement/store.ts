import { ONE_TIME_VERIFICATION_MS, type EntitlementKind, type OneTimeCatalog } from "./one-time-policy";
import { bytesToHex, hmacSha256 } from "../util";

export type EntitlementStatus = "active" | "grace" | "expired" | "revoked";

export type EntitlementRow = {
  id: string;
  product_id: string;
  environment: string;
  status: EntitlementStatus;
  kind: EntitlementKind;
  expires_at: number;
  grace_until: number | null;
  revoked_at: number | null;
  purchase_at: number;
  created_at: number;
  updated_at: number;
  last_verified_at: number | null;
  last_notification_at: number | null;
  last_notification_signed_at: number | null;
  app_transaction_hash: string | null;
  consent_stopped_at: number | null;
};

export type DeviceRow = { device_id: string; last_room: string | null };
export type EntitlementDeviceRow = EntitlementRow & { device_room: string | null };

type AccessRow = Pick<EntitlementRow, "expires_at" | "grace_until"> & {
  kind?: EntitlementKind; last_verified_at?: number | null; product_id?: string;
};
export const accessEndMs = (row: AccessRow) => row.kind === "lifetime" || row.kind === "founder"
  ? (row.last_verified_at ?? 0) + ONE_TIME_VERIFICATION_MS : Math.max(row.expires_at, row.grace_until ?? 0);

export const hasAccess = (row: AccessRow & { status: EntitlementStatus; revoked_at?: number | null; consent_stopped_at?: number | null }, now: number, oneTimeProducts?: OneTimeCatalog) =>
  (row.kind === undefined || row.kind === "subscription" || (row.product_id !== undefined && oneTimeProducts?.get(row.product_id) === row.kind)) &&
  (row.status === "active" || row.status === "grace") && accessEndMs(row) > now &&
  (row.kind === undefined || row.kind === "subscription" || (typeof row.last_verified_at === "number" && Number.isFinite(row.last_verified_at) && row.last_verified_at > 0 && row.last_verified_at <= now)) &&
  row.revoked_at == null && row.consent_stopped_at == null;

export async function entitlementIdFor(hashKey: string, originalTransactionId: string): Promise<string> {
  return bytesToHex(await hmacSha256(hashKey, `otid:${originalTransactionId}`));
}

export async function appTransactionHashFor(hashKey: string, appTransactionId: string): Promise<string> {
  return bytesToHex(await hmacSha256(hashKey, `atid:${appTransactionId}`));
}

export type UpsertEntitlement = {
  id: string;
  productId: string;
  environment: string;
  status: EntitlementStatus;
  expiresAt: number;
  kind?: EntitlementKind;
  graceUntil?: number | null;
  revokedAt?: number | null;
  /** Signed transaction purchase time; only a later purchase may clear an existing refund. */
  purchaseAt?: number;
  /** Apple's explicit refund reversal may clear a refund without a new purchase. */
  refundReversed?: boolean;
  /** Verified outer notification signedDate, never arrival time. */
  notificationSignedAt?: number;
  /** HMAC of the transaction's appTransactionId, the key a parental consent withdrawal names. */
  appTransactionHash?: string;
  source: "verify" | "notification" | "recheck";
};

/** Returns whether this purchase-versioned event changed the row. */
export async function upsertEntitlement(db: D1Database, fields: UpsertEntitlement, now: number): Promise<boolean> {
  const verified = fields.source === "verify" ? now : null;
  const notified = fields.source === "notification" ? now : null;
  const signed = fields.source === "notification" && Number.isFinite(fields.notificationSignedAt) && (fields.notificationSignedAt ?? 0) > 0
    ? fields.notificationSignedAt! : null;
  const result = await db.prepare(`
    INSERT INTO entitlements (id, product_id, environment, status, expires_at, grace_until, revoked_at, created_at, updated_at, last_verified_at, last_notification_at, purchase_at,
      app_transaction_hash, consent_stopped_at, kind, last_notification_signed_at)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, ?9, ?10, ?11,
      ?13, (SELECT stopped_at FROM consent_stops WHERE app_transaction_hash = ?13), ?14, ?15)
    ON CONFLICT(id) DO UPDATE SET
      product_id = excluded.product_id,
      kind = excluded.kind,
      environment = excluded.environment,
      status = excluded.status,
      expires_at = MAX(entitlements.expires_at, excluded.expires_at),
      grace_until = excluded.grace_until,
      revoked_at = excluded.revoked_at,
      purchase_at = excluded.purchase_at,
      updated_at = excluded.updated_at,
      last_verified_at = COALESCE(excluded.last_verified_at, entitlements.last_verified_at),
      last_notification_at = COALESCE(excluded.last_notification_at, entitlements.last_notification_at),
      last_notification_signed_at = COALESCE(excluded.last_notification_signed_at, entitlements.last_notification_signed_at),
      app_transaction_hash = COALESCE(excluded.app_transaction_hash, entitlements.app_transaction_hash),
      consent_stopped_at = COALESCE(entitlements.consent_stopped_at, excluded.consent_stopped_at)
    WHERE excluded.kind = entitlements.kind AND (excluded.kind = 'subscription' OR excluded.product_id = entitlements.product_id)
      AND excluded.environment = entitlements.environment AND excluded.purchase_at >= entitlements.purchase_at
      AND (excluded.kind = 'subscription' OR ?10 IS NULL OR
        (?15 IS NOT NULL AND (entitlements.last_notification_signed_at IS NULL OR ?15 > entitlements.last_notification_signed_at
          OR (?15 = entitlements.last_notification_signed_at AND excluded.revoked_at IS NOT NULL))))
      AND (entitlements.revoked_at IS NULL OR excluded.revoked_at IS NOT NULL
        OR excluded.purchase_at > entitlements.revoked_at OR (?12 = 1 AND
          (excluded.kind = 'subscription' OR ?15 > entitlements.revoked_at)))
  `).bind(fields.id, fields.productId, fields.environment, fields.status, fields.expiresAt,
    fields.graceUntil ?? null, fields.revokedAt ?? null, now, verified, notified,
    fields.purchaseAt ?? 0, fields.refundReversed ? 1 : 0, fields.appTransactionHash ?? null, fields.kind ?? "subscription", signed).run();
  return result.meta.changes > 0;
}

export async function getEntitlement(db: D1Database, id: string): Promise<EntitlementRow | null> {
  return db.prepare("SELECT * FROM entitlements WHERE id = ?1").bind(id).first<EntitlementRow>();
}

/** The subscription as seen from one device: null unless that device is still linked to it. */
export async function entitlementForDevice(db: D1Database, id: string, deviceId: string): Promise<EntitlementDeviceRow | null> {
  return db.prepare(`
    SELECT e.*, d.last_room AS device_room FROM entitlements e
    JOIN entitlement_devices d ON d.entitlement_id = e.id AND d.device_id = ?2
    WHERE e.id = ?1
  `).bind(id, deviceId).first<EntitlementDeviceRow>();
}

const STALE_DEVICE_MS = 30 * 24 * 60 * 60 * 1000;

/**
 * Links a device to a subscription, at most `maxDevices` per subscription. The count and the insert are one
 * statement, so parallel calls cannot exceed the cap. A slot held by a device unseen for 30 days is reclaimed.
 */
export async function linkDevice(db: D1Database, id: string, deviceId: string, now: number, maxDevices: number): Promise<"linked" | "device_limit"> {
  const insert = () => db.prepare(`
    INSERT INTO entitlement_devices (entitlement_id, device_id, first_seen, last_seen)
    SELECT ?1, ?2, ?3, ?3
    WHERE (SELECT COUNT(*) FROM entitlement_devices WHERE entitlement_id = ?1 AND device_id <> ?2) < ?4
    ON CONFLICT(entitlement_id, device_id) DO UPDATE SET last_seen = excluded.last_seen
  `).bind(id, deviceId, now, maxDevices).run();
  if ((await insert()).meta.changes > 0) return "linked";
  const reclaimed = await db.prepare(`
    DELETE FROM entitlement_devices WHERE rowid IN (
      SELECT rowid FROM entitlement_devices WHERE entitlement_id = ?1 AND last_seen < ?2 ORDER BY last_seen ASC LIMIT 1
    )
  `).bind(id, now - STALE_DEVICE_MS).run();
  if (reclaimed.meta.changes === 0) return "device_limit";
  return (await insert()).meta.changes > 0 ? "linked" : "device_limit";
}

export async function unlinkDeviceIfInRoom(db: D1Database, id: string, deviceId: string, room: string | null): Promise<boolean> {
  const result = await db.prepare(
    "DELETE FROM entitlement_devices WHERE entitlement_id = ?1 AND device_id = ?2 AND last_room IS ?3",
  ).bind(id, deviceId, room).run();
  return result.meta.changes > 0;
}

/** Compare-and-swap the single live room. A concurrent claim or unlink can never be silently overwritten. */
export async function claimDeviceRoom(db: D1Database, id: string, deviceId: string, room: string, now: number): Promise<{ claimed: boolean; previous: string | null }> {
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const row = await db.prepare("SELECT last_room FROM entitlement_devices WHERE entitlement_id = ?1 AND device_id = ?2")
      .bind(id, deviceId).first<{ last_room: string | null }>();
    if (!row) return { claimed: false, previous: null };
    const result = await db.prepare(
      "UPDATE entitlement_devices SET last_room = ?3, last_seen = ?4 WHERE entitlement_id = ?1 AND device_id = ?2 AND last_room IS ?5",
    ).bind(id, deviceId, room, now, row.last_room).run();
    if (result.meta.changes > 0) return { claimed: true, previous: row.last_room };
  }
  // Contention or storage trouble is a local-only admission, never a second relay owner.
  return { claimed: false, previous: null };
}

/** Undo a claim only if no newer room took ownership in the meantime. */
export async function restoreDeviceRoom(db: D1Database, id: string, deviceId: string, room: string, previous: string | null): Promise<void> {
  await db.prepare(
    "UPDATE entitlement_devices SET last_room = ?4 WHERE entitlement_id = ?1 AND device_id = ?2 AND last_room = ?3",
  ).bind(id, deviceId, room, previous).run();
}

export async function devicesForEntitlement(db: D1Database, id: string): Promise<DeviceRow[]> {
  return (await db.prepare("SELECT device_id, last_room FROM entitlement_devices WHERE entitlement_id = ?1").bind(id).all<DeviceRow>()).results;
}

export async function isDeviceLinked(db: D1Database, id: string, deviceId: string): Promise<boolean> {
  const row = await db.prepare("SELECT 1 AS present FROM entitlement_devices WHERE entitlement_id = ?1 AND device_id = ?2").bind(id, deviceId).first();
  return row !== null;
}

export async function markStatus(db: D1Database, id: string, status: EntitlementStatus, now: number, extra: { expiresAt?: number; graceUntil?: number | null; revokedAt?: number | null } = {}): Promise<boolean> {
  const result = await db.prepare(`
    UPDATE entitlements SET
      status = ?2,
      expires_at = COALESCE(?3, expires_at),
      grace_until = CASE WHEN ?4 IS NULL THEN grace_until ELSE ?4 END,
      revoked_at = CASE WHEN ?5 IS NULL THEN revoked_at ELSE ?5 END,
      updated_at = ?6,
      last_notification_at = ?6
    WHERE id = ?1
  `).bind(id, status, extra.expiresAt ?? null, extra.graceUntil ?? null, extra.revokedAt ?? null, now).run();
  return result.meta.changes > 0;
}

export async function consentStopped(db: D1Database, appTransactionHash: string): Promise<boolean> {
  return (await db.prepare("SELECT 1 AS present FROM consent_stops WHERE app_transaction_hash = ?1").bind(appTransactionHash).first()) !== null;
}

/** Records a consent withdrawal and stops every subscription bought under that app transaction. Returns the newly stopped ids. */
export async function stopForConsent(db: D1Database, appTransactionHash: string, environment: string, now: number): Promise<string[]> {
  const [, stopped] = await db.batch<{ id: string }>([
    db.prepare("INSERT OR IGNORE INTO consent_stops (app_transaction_hash, environment, stopped_at) VALUES (?1, ?2, ?3)")
      .bind(appTransactionHash, environment, now),
    db.prepare("UPDATE entitlements SET consent_stopped_at = ?2, updated_at = ?2, last_notification_at = ?2 WHERE app_transaction_hash = ?1 AND consent_stopped_at IS NULL RETURNING id")
      .bind(appTransactionHash, now),
  ]);
  return (stopped?.results ?? []).map(row => row.id);
}

export async function notificationSeen(db: D1Database, uuid: string): Promise<boolean> {
  return (await db.prepare("SELECT 1 AS present FROM notifications WHERE uuid = ?1").bind(uuid).first()) !== null;
}

/** Returns false when the notification UUID was already recorded. */
export async function recordNotification(db: D1Database, fields: { uuid: string; type: string; subtype?: string; environment?: string; entitlementId?: string }, now: number): Promise<boolean> {
  const result = await db.prepare(`
    INSERT OR IGNORE INTO notifications (uuid, notification_type, subtype, environment, entitlement_id, received_at)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6)
  `).bind(fields.uuid, fields.type, fields.subtype ?? null, fields.environment ?? null, fields.entitlementId ?? null, now).run();
  return result.meta.changes > 0;
}

export async function touchRoom(db: D1Database, room: string, now: number): Promise<void> {
  await db.prepare(`
    INSERT INTO rooms (id, first_seen, last_seen, status, registrations) VALUES (?1, ?2, ?2, 'active', 1)
    ON CONFLICT(id) DO UPDATE SET last_seen = excluded.last_seen, registrations = rooms.registrations + 1
  `).bind(room, now).run();
}

export async function roomStatus(db: D1Database, room: string): Promise<"active" | "blocked" | undefined> {
  const row = await db.prepare("SELECT status FROM rooms WHERE id = ?1").bind(room).first<{ status: "active" | "blocked" }>();
  return row?.status;
}

export async function setRoomStatus(db: D1Database, room: string, status: "active" | "blocked", now: number): Promise<void> {
  await db.prepare(`
    INSERT INTO rooms (id, first_seen, last_seen, status, registrations) VALUES (?1, ?2, ?2, ?3, 0)
    ON CONFLICT(id) DO UPDATE SET status = excluded.status
  `).bind(room, now, status).run();
}

/** Forgets a room's registry row and device references. A blocked room keeps its block. */
export async function deleteRoom(db: D1Database, room: string): Promise<void> {
  await db.batch([
    db.prepare("DELETE FROM rooms WHERE id = ?1 AND status <> 'blocked'").bind(room),
    db.prepare("UPDATE entitlement_devices SET last_room = NULL WHERE last_room = ?1").bind(room),
  ]);
}

export async function audit(db: D1Database, event: string, fields: { roomFp?: string; entitlementId?: string; detail?: string }, now: number): Promise<void> {
  await db.prepare("INSERT INTO audit (at, event, room_fp, entitlement_id, detail) VALUES (?1, ?2, ?3, ?4, ?5)")
    .bind(now, event, fields.roomFp ?? null, fields.entitlementId ?? null, fields.detail ?? null).run();
}

const DAY = 24 * 60 * 60 * 1000;

export async function purgeRetention(db: D1Database, now: number): Promise<Record<string, number>> {
  const results = await db.batch([
    db.prepare("DELETE FROM notifications WHERE received_at < ?1").bind(now - 90 * DAY),
    db.prepare("DELETE FROM audit WHERE at < ?1").bind(now - 30 * DAY),
    db.prepare("DELETE FROM entitlement_devices WHERE entitlement_id IN (SELECT id FROM entitlements WHERE kind = 'subscription' AND MAX(expires_at, COALESCE(grace_until, 0)) < ?1)").bind(now - 90 * DAY),
    db.prepare("DELETE FROM entitlements WHERE kind = 'subscription' AND MAX(expires_at, COALESCE(grace_until, 0)) < ?1").bind(now - 90 * DAY),
    db.prepare("DELETE FROM rooms WHERE last_seen < ?1 AND status = 'active'").bind(now - 365 * DAY),
    // A stop outlives its subscriptions by a year so a lapsed plan cannot be verified back into use right away.
    db.prepare(`DELETE FROM consent_stops WHERE stopped_at < ?1 AND NOT EXISTS
      (SELECT 1 FROM entitlements WHERE entitlements.app_transaction_hash = consent_stops.app_transaction_hash)`).bind(now - 365 * DAY),
  ]);
  const [notifications, auditRows, devices, entitlements, rooms, consentStops] = results.map(result => result.meta.changes);
  return { notifications: notifications ?? 0, audit: auditRows ?? 0, devices: devices ?? 0, entitlements: entitlements ?? 0, rooms: rooms ?? 0,
    consentStops: consentStops ?? 0 };
}

export async function readinessCounts(db: D1Database, now: number): Promise<Record<string, number>> {
  const [entitlements, sandbox, rooms, blocked, notifications] = await db.batch([
    db.prepare("SELECT COUNT(*) AS n FROM entitlements WHERE status IN ('active','grace') AND consent_stopped_at IS NULL AND (CASE WHEN kind = 'subscription' THEN MAX(expires_at, COALESCE(grace_until, 0)) ELSE COALESCE(last_verified_at, 0) + 86400000 END) > ?1").bind(now),
    db.prepare("SELECT COUNT(*) AS n FROM entitlements WHERE environment = 'Sandbox' AND (CASE WHEN kind = 'subscription' THEN MAX(expires_at, COALESCE(grace_until, 0)) ELSE COALESCE(last_verified_at, 0) + 86400000 END) > ?1").bind(now),
    db.prepare("SELECT COUNT(*) AS n FROM rooms WHERE last_seen > ?1").bind(now - 30 * DAY),
    db.prepare("SELECT COUNT(*) AS n FROM rooms WHERE status = 'blocked'"),
    db.prepare("SELECT COUNT(*) AS n FROM notifications WHERE received_at > ?1").bind(now - DAY),
  ]);
  const count = (result: D1Result | undefined) => Number((result?.results[0] as { n?: number } | undefined)?.n ?? 0);
  return {
    activeEntitlements: count(entitlements),
    activeSandboxEntitlements: count(sandbox),
    roomsSeen30d: count(rooms),
    blockedRooms: count(blocked),
    notifications24h: count(notifications),
  };
}
