ALTER TABLE users ADD COLUMN IF NOT EXISTS clerk_user_id text;

CREATE UNIQUE INDEX IF NOT EXISTS users_clerk_user_id_idx
  ON users(clerk_user_id)
  WHERE clerk_user_id IS NOT NULL;

DROP TABLE IF EXISTS refresh_tokens;
DROP TABLE IF EXISTS auth_identities;
