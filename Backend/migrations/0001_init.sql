-- Farside backend: entitlements, devices, notification dedupe, room registry, audit.
-- Timestamps are milliseconds since the Unix epoch. No names, emails, Apple IDs or payloads.

CREATE TABLE entitlements (
  id TEXT PRIMARY KEY,                 -- HMAC-SHA256(originalTransactionId) hex
  product_id TEXT NOT NULL,
  environment TEXT NOT NULL,           -- Production | Sandbox | Xcode
  status TEXT NOT NULL,                -- active | grace | expired | revoked
  expires_at INTEGER NOT NULL,
  grace_until INTEGER,
  revoked_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_verified_at INTEGER,
  last_notification_at INTEGER
);
CREATE INDEX entitlements_status_expires ON entitlements(status, expires_at);

CREATE TABLE entitlement_devices (
  entitlement_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  last_room TEXT,                      -- room id of the last entitled registration, for revoke pushes
  PRIMARY KEY (entitlement_id, device_id)
);
CREATE INDEX entitlement_devices_device ON entitlement_devices(device_id);

CREATE TABLE notifications (
  uuid TEXT PRIMARY KEY,
  notification_type TEXT NOT NULL,
  subtype TEXT,
  environment TEXT,
  entitlement_id TEXT,
  received_at INTEGER NOT NULL
);
CREATE INDEX notifications_received ON notifications(received_at);

CREATE TABLE rooms (
  id TEXT PRIMARY KEY,                 -- SHA256(hostToken), as sent by the Mac
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'active', -- active | blocked
  registrations INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX rooms_last_seen ON rooms(last_seen);

CREATE TABLE audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at INTEGER NOT NULL,
  event TEXT NOT NULL,
  room_fp TEXT,                        -- first 8 hex of a room id
  entitlement_id TEXT,
  detail TEXT
);
CREATE INDEX audit_at ON audit(at);
