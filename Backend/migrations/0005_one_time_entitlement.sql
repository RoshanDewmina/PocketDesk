-- Old verified rows remain subscriptions. One-time rights have no economic period end (expires_at=0).
-- Their short authorization freshness is last_verified_at, not a fabricated distant expiry.
ALTER TABLE entitlements ADD COLUMN kind TEXT NOT NULL DEFAULT 'subscription'
  CHECK (kind IN ('subscription', 'lifetime', 'founder'));
