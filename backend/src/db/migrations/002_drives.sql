CREATE TABLE IF NOT EXISTS drives (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  started_at timestamptz NOT NULL,
  duration_seconds double precision NOT NULL,
  distance_meters double precision NOT NULL,
  score integer NOT NULL,
  top_speed_meters_per_second double precision NOT NULL,
  event_count integer NOT NULL DEFAULT 0,
  recording_time_zone_identifier text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

CREATE INDEX IF NOT EXISTS drives_user_started_idx ON drives(user_id, started_at DESC);
CREATE INDEX IF NOT EXISTS drives_user_updated_idx ON drives(user_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS saved_routes (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  label text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS saved_routes_user_idx ON saved_routes(user_id);
