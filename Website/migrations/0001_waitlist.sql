-- Beta waitlist. `consent` records which sign-up wording the person agreed to (CASL keeps the
-- burden of proving consent on the sender), and `unsubscribe_token` backs the link in every email.
CREATE TABLE waitlist (
  id INTEGER PRIMARY KEY,
  email TEXT NOT NULL UNIQUE COLLATE NOCASE,
  source TEXT NOT NULL,
  consent TEXT NOT NULL,
  unsubscribe_token TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  unsubscribed_at TEXT
);

-- Sign-up attempts per salted IP hash per 10-minute window; rows older than an hour are pruned
-- on every request, so no address (hashed or not) is kept longer than that.
CREATE TABLE waitlist_rate (
  ip_hash TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  hits INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (ip_hash, window_start)
);
