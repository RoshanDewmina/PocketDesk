-- Additive preferences: old registrations continue to receive attention only.
ALTER TABLE push_registrations ADD COLUMN completed_enabled INTEGER NOT NULL DEFAULT 0;
ALTER TABLE push_registrations ADD COLUMN failed_enabled INTEGER NOT NULL DEFAULT 0;
ALTER TABLE push_events ADD COLUMN event TEXT NOT NULL DEFAULT 'needs_user';
ALTER TABLE push_events ADD COLUMN run_hash TEXT;
-- Hourly admission survives the 15-minute notification/report retention window.
CREATE TABLE push_admissions (
  room TEXT NOT NULL,
  pairing_hash TEXT NOT NULL,
  id TEXT NOT NULL,
  session_hash TEXT NOT NULL,
  run_hash TEXT NOT NULL,
  event TEXT NOT NULL,
  admitted_at INTEGER NOT NULL,
  PRIMARY KEY (room, pairing_hash, id)
);
CREATE INDEX push_admissions_rate ON push_admissions(room, pairing_hash, admitted_at);
INSERT INTO push_admissions (room,pairing_hash,id,session_hash,run_hash,event,admitted_at)
  SELECT room,pairing_hash,id,session_hash,session_hash,event,raised_at FROM push_events;
