import { getPool } from "../pool.js";
import type {
  DriveInputRecord,
  DriveRecord,
  DriveStats,
  SavedRouteInputRecord,
  SavedRouteRecord,
} from "../types.js";
import { queryDatabase } from "./helpers.js";

interface DriveRow extends Record<string, unknown> {
  id: string;
  user_id: string;
  started_at: Date;
  duration_seconds: number;
  distance_meters: number;
  score: number;
  top_speed_meters_per_second: number;
  event_count: number;
  recording_time_zone_identifier: string | null;
  payload: Record<string, unknown>;
  created_at: Date;
  updated_at: Date;
}

interface DriveStatsRow extends Record<string, unknown> {
  total_drives: number | string;
  total_distance_meters: number | string | null;
  total_duration_seconds: number | string | null;
  average_score: number | string | null;
}

interface SavedRouteRow extends Record<string, unknown> {
  id: string;
  user_id: string;
  label: string;
  payload: Record<string, unknown>;
  created_at: Date;
  updated_at: Date;
}

function mapDrive(row: DriveRow): DriveRecord {
  return {
    id: row.id,
    userId: row.user_id,
    startedAt: new Date(row.started_at),
    durationSeconds: Number(row.duration_seconds),
    distanceMeters: Number(row.distance_meters),
    score: Number(row.score),
    topSpeedMetersPerSecond: Number(row.top_speed_meters_per_second),
    eventCount: Number(row.event_count),
    recordingTimeZoneIdentifier: row.recording_time_zone_identifier,
    payload: { ...row.payload },
    createdAt: new Date(row.created_at),
    updatedAt: new Date(row.updated_at),
  };
}

function mapSavedRoute(row: SavedRouteRow): SavedRouteRecord {
  return {
    id: row.id,
    userId: row.user_id,
    label: row.label,
    payload: { ...row.payload },
    createdAt: new Date(row.created_at),
    updatedAt: new Date(row.updated_at),
  };
}

function boundedLimit(limit: number | undefined): number {
  if (limit === undefined) return 50;
  return Math.min(200, Math.max(1, Math.trunc(limit)));
}

const driveColumns = `
  id, user_id, started_at, duration_seconds, distance_meters, score,
  top_speed_meters_per_second, event_count, recording_time_zone_identifier,
  payload, created_at, updated_at
`;

/**
 * Pages drive history newest-first.
 *
 * `started_at` alone is not a stable sort key: two drives can share a
 * timestamp, and when such a pair straddles a page boundary a cursor of
 * "everything strictly before this timestamp" skips the rest of the group
 * entirely, dropping those drives from sync permanently. Ordering and
 * paginating by the `(started_at, id)` pair makes the sequence total, so every
 * row is visited exactly once.
 *
 * `beforeId` is optional so cursors issued by older clients (a bare timestamp)
 * still page, just with the original tie behaviour.
 */
export async function listDrives(
  userId: string,
  options: { limit?: number; before?: Date; beforeId?: string } = {}
): Promise<DriveRecord[]> {
  const limit = boundedLimit(options.limit);
  const values: unknown[] = [userId];
  let beforeClause = "";
  if (options.before && options.beforeId) {
    values.push(options.before, options.beforeId);
    beforeClause = " AND (started_at, id) < ($2, $3)";
  } else if (options.before) {
    values.push(options.before);
    beforeClause = " AND started_at < $2";
  }
  values.push(limit);
  const limitParameter = `$${values.length}`;
  const result = await queryDatabase<DriveRow>(getPool(), `
    SELECT ${driveColumns}
    FROM drives
    WHERE user_id = $1 AND deleted_at IS NULL${beforeClause}
    ORDER BY started_at DESC, id DESC
    LIMIT ${limitParameter}
  `, values);
  return result.rows.map(mapDrive);
}

export async function getDrive(userId: string, driveId: string): Promise<DriveRecord | null> {
  const result = await queryDatabase<DriveRow>(getPool(), `
    SELECT ${driveColumns}
    FROM drives
    WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL
    LIMIT 1
  `, [userId, driveId]);
  const row = result.rows[0];
  return row ? mapDrive(row) : null;
}

export async function upsertDrives(userId: string, drives: DriveInputRecord[]): Promise<DriveRecord[]> {
  if (drives.length === 0) return [];
  const values: unknown[] = [];
  const placeholders = drives.map((drive, index) => {
    const offset = index * 10;
    values.push(
      drive.id,
      userId,
      drive.startedAt,
      drive.durationSeconds,
      drive.distanceMeters,
      drive.score,
      drive.topSpeedMetersPerSecond,
      drive.eventCount,
      drive.recordingTimeZoneIdentifier,
      JSON.stringify(drive.payload),
    );
    return `($${offset + 1}, $${offset + 2}, $${offset + 3}, $${offset + 4}, $${offset + 5}, $${offset + 6}, $${offset + 7}, $${offset + 8}, $${offset + 9}, $${offset + 10}::jsonb)`;
  }).join(",\n");

  const result = await queryDatabase<DriveRow>(getPool(), `
    INSERT INTO drives (
      id, user_id, started_at, duration_seconds, distance_meters, score,
      top_speed_meters_per_second, event_count, recording_time_zone_identifier, payload
    )
    VALUES ${placeholders}
    ON CONFLICT (id) DO UPDATE SET
      started_at = EXCLUDED.started_at,
      duration_seconds = EXCLUDED.duration_seconds,
      distance_meters = EXCLUDED.distance_meters,
      score = EXCLUDED.score,
      top_speed_meters_per_second = EXCLUDED.top_speed_meters_per_second,
      event_count = EXCLUDED.event_count,
      recording_time_zone_identifier = EXCLUDED.recording_time_zone_identifier,
      payload = EXCLUDED.payload,
      updated_at = now()
    WHERE drives.user_id = EXCLUDED.user_id
    RETURNING ${driveColumns}
  `, values);
  return result.rows.map(mapDrive);
}

export async function softDeleteDrive(userId: string, driveId: string): Promise<boolean> {
  const result = await queryDatabase(getPool(), `
    UPDATE drives
    SET deleted_at = COALESCE(deleted_at, now()), updated_at = now()
    WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL
  `, [userId, driveId]);
  return (result.rowCount ?? 0) > 0;
}

export async function countDrives(userId: string): Promise<number> {
  const result = await queryDatabase<{ count: number | string }>(getPool(), `
    SELECT COUNT(*)::int AS count
    FROM drives
    WHERE user_id = $1 AND deleted_at IS NULL
  `, [userId]);
  return Number(result.rows[0]?.count ?? 0);
}

export async function aggregateDriveStats(userId: string): Promise<DriveStats> {
  const result = await queryDatabase<DriveStatsRow>(getPool(), `
    SELECT
      COUNT(*)::int AS total_drives,
      COALESCE(SUM(distance_meters), 0)::double precision AS total_distance_meters,
      COALESCE(SUM(duration_seconds), 0)::double precision AS total_duration_seconds,
      AVG(score)::double precision AS average_score
    FROM drives
    WHERE user_id = $1 AND deleted_at IS NULL
  `, [userId]);
  const row = result.rows[0];
  return {
    totalDrives: Number(row?.total_drives ?? 0),
    totalDistanceMeters: Number(row?.total_distance_meters ?? 0),
    totalDurationSeconds: Number(row?.total_duration_seconds ?? 0),
    averageScore: row?.average_score === null || row?.average_score === undefined ? null : Number(row.average_score),
  };
}

export async function listSavedRoutes(userId: string): Promise<SavedRouteRecord[]> {
  const result = await queryDatabase<SavedRouteRow>(getPool(), `
    SELECT id, user_id, label, payload, created_at, updated_at
    FROM saved_routes
    WHERE user_id = $1
    ORDER BY updated_at DESC
  `, [userId]);
  return result.rows.map(mapSavedRoute);
}

export async function upsertSavedRoute(
  userId: string,
  route: SavedRouteInputRecord
): Promise<SavedRouteRecord | null> {
  const result = await queryDatabase<SavedRouteRow>(getPool(), `
    INSERT INTO saved_routes (id, user_id, label, payload)
    VALUES ($1, $2, $3, $4::jsonb)
    ON CONFLICT (id) DO UPDATE SET
      label = EXCLUDED.label,
      payload = EXCLUDED.payload,
      updated_at = now()
    WHERE saved_routes.user_id = EXCLUDED.user_id
    RETURNING id, user_id, label, payload, created_at, updated_at
  `, [route.id, userId, route.label, JSON.stringify(route.payload)]);
  const row = result.rows[0];
  return row ? mapSavedRoute(row) : null;
}

export async function deleteSavedRoute(userId: string, routeId: string): Promise<boolean> {
  const result = await queryDatabase(getPool(), `
    DELETE FROM saved_routes
    WHERE user_id = $1 AND id = $2
  `, [userId, routeId]);
  return (result.rowCount ?? 0) > 0;
}

export const getDriveStats = aggregateDriveStats;

export type { DriveRow, SavedRouteRow };
