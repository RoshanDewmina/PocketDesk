-- Parental consent withdrawal (App Store Server Notification RESCIND_CONSENT) stops Anywhere for the
-- app transaction it names. Apple identifies it by appTransactionId, which purchase transactions also carry.
-- Only HMAC-SHA256(appTransactionId) is stored, keyed like entitlement ids.
ALTER TABLE entitlements ADD COLUMN app_transaction_hash TEXT;
-- Set once and never cleared by a renewal or a later purchase notice.
ALTER TABLE entitlements ADD COLUMN consent_stopped_at INTEGER;
CREATE INDEX entitlements_app_transaction ON entitlements(app_transaction_hash);

CREATE TABLE consent_stops (
  app_transaction_hash TEXT PRIMARY KEY,
  environment TEXT NOT NULL,           -- Production | Sandbox | Xcode
  stopped_at INTEGER NOT NULL
);
