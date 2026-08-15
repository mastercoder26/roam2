import { getPool } from "../pool.js";
import type { PublicUser, UserRecord } from "../types.js";
import { queryDatabase } from "./helpers.js";

interface UserRow extends Record<string, unknown> {
  id: string;
  clerk_user_id: string | null;
  email: string;
  display_name: string | null;
  created_at: Date;
  updated_at: Date;
  email_verified_at: Date | null;
  deleted_at: Date | null;
}

function mapUser(row: UserRow): UserRecord {
  return {
    id: row.id,
    clerkUserId: row.clerk_user_id,
    email: row.email,
    displayName: row.display_name,
    createdAt: new Date(row.created_at),
    updatedAt: new Date(row.updated_at),
    emailVerifiedAt: row.email_verified_at ? new Date(row.email_verified_at) : null,
    deletedAt: row.deleted_at ? new Date(row.deleted_at) : null,
  };
}

export function toPublicUser(user: UserRecord): PublicUser {
  return { id: user.id, email: user.email, displayName: user.displayName };
}

export async function findUserById(id: string): Promise<UserRecord | null> {
  const result = await queryDatabase<UserRow>(getPool(), `
    SELECT id, clerk_user_id, email, display_name, created_at, updated_at,
           email_verified_at, deleted_at
    FROM users WHERE id = $1 AND deleted_at IS NULL LIMIT 1
  `, [id]);
  const row = result.rows[0];
  return row ? mapUser(row) : null;
}

export async function findOrCreateByClerkId(input: {
  clerkUserId: string;
  email: string | null;
  displayName: string | null;
}): Promise<UserRecord> {
  const result = await queryDatabase<UserRow>(getPool(), `
    INSERT INTO users (clerk_user_id, email, password_hash, display_name)
    VALUES (
      $1,
      COALESCE($2, 'clerk_' || $1 || '@clerk.local'),
      NULL,
      $3
    )
    ON CONFLICT (clerk_user_id) WHERE clerk_user_id IS NOT NULL DO UPDATE SET
      email = CASE WHEN $2::text IS NULL THEN users.email ELSE EXCLUDED.email END,
      display_name = CASE WHEN $3::text IS NULL THEN users.display_name ELSE EXCLUDED.display_name END,
      deleted_at = NULL,
      updated_at = now()
    RETURNING id, clerk_user_id, email, display_name, created_at, updated_at,
              email_verified_at, deleted_at
  `, [input.clerkUserId, input.email, input.displayName]);
  const row = result.rows[0];
  if (!row) throw new Error("User insert returned no row");
  return mapUser(row);
}

export async function deleteUser(id: string): Promise<void> {
  await queryDatabase(getPool(), `
    DELETE FROM users WHERE id = $1
  `, [id]);
}

export type { UserRecord };
export const findById = findUserById;
