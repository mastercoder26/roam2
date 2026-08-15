import { getPool } from "../pool.js";
import type { DriverStage, ProfileRecord } from "../types.js";
import { queryDatabase } from "./helpers.js";

interface ProfileRow extends Record<string, unknown> {
  user_id: string;
  display_name: string | null;
  stage: DriverStage | null;
  payload: Record<string, unknown>;
  updated_at: Date;
}

function mapProfile(row: ProfileRow): ProfileRecord {
  return { userId: row.user_id, displayName: row.display_name, stage: row.stage, payload: { ...row.payload }, updatedAt: new Date(row.updated_at) };
}

export async function getProfile(userId: string): Promise<ProfileRecord> {
  const pool = getPool();
  await queryDatabase(pool, "INSERT INTO driver_profiles (user_id) VALUES ($1) ON CONFLICT (user_id) DO NOTHING", [userId]);
  const result = await queryDatabase<ProfileRow>(pool, "SELECT user_id, display_name, stage, payload, updated_at FROM driver_profiles WHERE user_id = $1", [userId]);
  const row = result.rows[0];
  if (!row) throw new Error("Profile insert returned no row");
  return mapProfile(row);
}

export async function updateProfile(userId: string, input: {
  displayName?: string;
  stage?: DriverStage;
  payload?: Record<string, unknown>;
}): Promise<ProfileRecord> {
  const result = await queryDatabase<ProfileRow>(getPool(), `
    INSERT INTO driver_profiles (user_id, display_name, stage, payload)
    VALUES ($1, $2, $3, COALESCE($4::jsonb, '{}'::jsonb))
    ON CONFLICT (user_id) DO UPDATE SET
      display_name = COALESCE(EXCLUDED.display_name, driver_profiles.display_name),
      stage = COALESCE(EXCLUDED.stage, driver_profiles.stage),
      payload = CASE WHEN $4::jsonb IS NULL THEN driver_profiles.payload ELSE EXCLUDED.payload END,
      updated_at = now()
    RETURNING user_id, display_name, stage, payload, updated_at
  `, [userId, input.displayName ?? null, input.stage ?? null, input.payload === undefined ? null : JSON.stringify(input.payload)]);
  const row = result.rows[0];
  if (!row) throw new Error("Profile update returned no row");
  return mapProfile(row);
}
