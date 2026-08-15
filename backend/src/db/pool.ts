import { createRequire } from "node:module";
import {
  createRequestId,
  DatabaseOperationError,
  DatabaseUnavailableError,
  logDatabaseFailure,
} from "../errors.js";

export interface QueryResult<Row extends Record<string, unknown> = Record<string, unknown>> {
  rows: Row[];
  rowCount: number | null;
}

export interface PoolClient {
  query<Row extends Record<string, unknown> = Record<string, unknown>>(
    text: string,
    values?: readonly unknown[]
  ): Promise<QueryResult<Row>>;
  release(): void;
}

export interface PoolLike {
  query<Row extends Record<string, unknown> = Record<string, unknown>>(
    text: string,
    values?: readonly unknown[]
  ): Promise<QueryResult<Row>>;
  connect(): Promise<PoolClient>;
  on(event: string, listener: (error: unknown) => void): PoolLike;
  end?(): Promise<void>;
}

type PgModule = {
  Pool: new (options: Record<string, unknown>) => PoolLike;
};

let pool: PoolLike | null = null;

export function isDatabaseConfigured(): boolean {
  return Boolean(process.env.DATABASE_URL?.trim());
}

function isLocalDatabaseUrl(databaseUrl: string): boolean {
  try {
    const hostname = new URL(databaseUrl).hostname.toLowerCase();
    return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1";
  } catch {
    return false;
  }
}

function createPool(): PoolLike {
  const databaseUrl = process.env.DATABASE_URL?.trim();
  if (!databaseUrl) throw new DatabaseUnavailableError("DATABASE_URL is not configured");

  const require = createRequire(import.meta.url);
  let pg: PgModule;
  try {
    pg = require("pg") as PgModule;
  } catch (error) {
    throw new DatabaseUnavailableError("The PostgreSQL driver is unavailable", { cause: error });
  }

  const sslDisabled = process.env.PGSSLMODE?.toLowerCase() === "disable";
  const options: Record<string, unknown> = {
    connectionString: databaseUrl,
    max: 10,
    connectionTimeoutMillis: 5_000,
    idleTimeoutMillis: 30_000,
    ...(sslDisabled || isLocalDatabaseUrl(databaseUrl)
      ? {}
      : { ssl: { rejectUnauthorized: false } }),
  };
  const createdPool = new pg.Pool(options);
  createdPool.on("error", (error) => {
    logDatabaseFailure(createRequestId(), { endpoint: "pool" }, error);
  });
  return createdPool;
}

export function getPool(): PoolLike {
  if (!isDatabaseConfigured()) {
    throw new DatabaseUnavailableError("DATABASE_URL is not configured");
  }
  if (pool === null) pool = createPool();
  return pool;
}

export async function queryDatabase<Row extends Record<string, unknown> = Record<string, unknown>>(
  text: string,
  values: readonly unknown[] = []
): Promise<QueryResult<Row>> {
  try {
    return await getPool().query<Row>(text, values);
  } catch (error) {
    if (error instanceof DatabaseUnavailableError) throw error;
    throw new DatabaseOperationError(error);
  }
}

export async function withTransaction<T>(
  operation: (client: PoolClient) => Promise<T>
): Promise<T> {
  let client: PoolClient | undefined;
  try {
    client = await getPool().connect();
    await client.query("BEGIN");
    const result = await operation(client);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    if (client) {
      try {
        await client.query("ROLLBACK");
      } catch {
        // The original database error is more useful to the caller.
      }
    }
    if (error instanceof DatabaseUnavailableError) throw error;
    throw new DatabaseOperationError(error);
  } finally {
    client?.release();
  }
}

export async function checkDatabase(): Promise<"up" | "down" | "unconfigured"> {
  if (!isDatabaseConfigured()) return "unconfigured";
  try {
    await queryDatabase("SELECT 1");
    return "up";
  } catch (error) {
    logDatabaseFailure(createRequestId(), { endpoint: "health" }, error);
    return "down";
  }
}

/** Test hook; it does not affect production behavior. */
export function setPoolForTests(nextPool: PoolLike | null): void {
  pool = nextPool;
}

export async function closePool(): Promise<void> {
  const currentPool = pool;
  pool = null;
  await currentPool?.end?.();
}
