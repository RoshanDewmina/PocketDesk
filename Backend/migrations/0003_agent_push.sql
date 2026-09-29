-- Pairing-scoped APNs registry and bounded request history. No agent text or screen data.
CREATE TABLE push_registrations (
  room TEXT PRIMARY KEY,
  device_token TEXT NOT NULL,
  environment TEXT NOT NULL,
  alerts_enabled INTEGER NOT NULL,
  time_sensitive INTEGER NOT NULL,
  show_agent_name INTEGER NOT NULL,
  locale TEXT NOT NULL,
  app_build TEXT NOT NULL,
  os_major INTEGER NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  updated_at INTEGER NOT NULL
);
CREATE TABLE push_events (
  room TEXT NOT NULL,
  id TEXT NOT NULL,
  session_hash TEXT NOT NULL,
  kind TEXT NOT NULL,
  raised_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (room, id)
);
CREATE INDEX push_events_room_time ON push_events(room, raised_at);
CREATE TABLE push_reports (
  room TEXT NOT NULL,
  id TEXT NOT NULL,
  action TEXT NOT NULL,
  reported_at INTEGER NOT NULL,
  PRIMARY KEY (room, id, action)
);
-- Only end pushes for a currently authenticated route epoch are supported.
CREATE TABLE activity_registrations (
  room TEXT NOT NULL,
  route_epoch TEXT NOT NULL,
  activity_id TEXT NOT NULL,
  push_token TEXT NOT NULL,
  environment TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  updated_at INTEGER NOT NULL,
  end_reason TEXT,
  end_at INTEGER,
  next_retry_at INTEGER,
  attempts INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (room, route_epoch, activity_id)
);
CREATE INDEX activity_registrations_room_epoch ON activity_registrations(room, route_epoch);
