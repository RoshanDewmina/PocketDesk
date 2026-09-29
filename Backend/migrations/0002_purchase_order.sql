-- Preserve the newest signed subscription purchase when notifications and verification race.
ALTER TABLE entitlements ADD COLUMN purchase_at INTEGER NOT NULL DEFAULT 0;
