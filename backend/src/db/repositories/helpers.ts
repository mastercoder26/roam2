import { DatabaseOperationError } from "../../errors.js";
import type { PoolLike, QueryResult } from "../pool.js";

export async function queryDatabase<Row extends Record<string, unknown>>(
  pool: PoolLike,
  text: string,
  values: readonly unknown[] = []
): Promise<QueryResult<Row>> {
  try {
    return await pool.query<Row>(text, values);
  } catch (error) {
    throw new DatabaseOperationError(error);
  }
}

export function isUniqueViolation(error: unknown): boolean {
  if (error instanceof DatabaseOperationError) {
    const original = error.originalError as { code?: unknown };
    return original?.code === "23505";
  }
  return false;
}
