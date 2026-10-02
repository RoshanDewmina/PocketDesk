-- Apple lookups require the original id: HMAC ids cannot be reversed. Never log this column.
-- It is retained only with its subscription row (the existing 90-day expired-row purge applies).
ALTER TABLE entitlements ADD COLUMN subscription_original_transaction_id TEXT;
ALTER TABLE entitlements ADD COLUMN last_recovery_attempt_at INTEGER;
CREATE TABLE subscription_recovery_cursors (
  environment TEXT PRIMARY KEY CHECK(environment IN ('Production','Sandbox')),
  start_at INTEGER NOT NULL,
  end_at INTEGER NOT NULL,
  pagination_token TEXT,
  completed_at INTEGER
);
CREATE TABLE subscription_recovery_lock (id INTEGER PRIMARY KEY CHECK(id=1), owner TEXT NOT NULL, lease_until INTEGER NOT NULL);
CREATE TABLE subscription_recovery_revocations (entitlement_id TEXT PRIMARY KEY, queued_at INTEGER NOT NULL, last_attempt_at INTEGER);
CREATE TRIGGER subscription_recovery_revoke_insert AFTER INSERT ON entitlements
WHEN NEW.kind='subscription' AND NEW.status='revoked'
BEGIN INSERT OR REPLACE INTO subscription_recovery_revocations (entitlement_id,queued_at) VALUES(NEW.id,NEW.updated_at); END;
CREATE TRIGGER subscription_recovery_revoke_update AFTER UPDATE ON entitlements
WHEN NEW.kind='subscription' AND NEW.status='revoked' AND (OLD.status<>'revoked' OR OLD.revoked_at IS NOT NEW.revoked_at)
BEGIN INSERT OR REPLACE INTO subscription_recovery_revocations (entitlement_id,queued_at) VALUES(NEW.id,NEW.updated_at); END;
CREATE TRIGGER subscription_recovery_delete AFTER DELETE ON entitlements
BEGIN DELETE FROM subscription_recovery_revocations WHERE entitlement_id=OLD.id; END;
