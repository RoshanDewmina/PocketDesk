-- Aggregate totals only. No identifier, exact timestamp, payload, or join key.
CREATE TABLE daily_metrics (
  day TEXT NOT NULL CHECK(length(day) = 10 AND day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  event TEXT NOT NULL CHECK(event IN (
    'host_registered', 'signaling_ready_free', 'signaling_ready_anywhere',
    'entitlement_verify_ok', 'entitlement_verify_rejected'
  )),
  count INTEGER NOT NULL CHECK(typeof(count) = 'integer' AND count > 0),
  PRIMARY KEY (day, event)
) WITHOUT ROWID;
