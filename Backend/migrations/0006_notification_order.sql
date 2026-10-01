-- Signed event order, distinct from delivery/arrival time; retained with refund tombstones.
ALTER TABLE entitlements ADD COLUMN last_notification_signed_at INTEGER;
