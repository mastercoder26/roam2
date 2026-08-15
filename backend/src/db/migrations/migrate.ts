import { readdir, readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { getPool } from "../pool.js";

const migrationsDirectory = dirname(fileURLToPath(import.meta.url));

export async function runMigrations(): Promise<string[]> {
  const pool = getPool();
  const client = await pool.connect();
  const applied: string[] = [];

  try {
    await client.query("BEGIN");
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version text PRIMARY KEY,
        applied_at timestamptz NOT NULL DEFAULT now()
      )
    `);
    const files = (await readdir(migrationsDirectory))
      .filter((file) => /^\d+_.+\.sql$/.test(file))
      .sort();

    for (const file of files) {
      const version = file.slice(0, file.indexOf("_"));
      const result = await client.query<{ version: string }>(
        "SELECT version FROM schema_migrations WHERE version = $1",
        [version]
      );
      if (result.rows.length > 0) continue;

      await client.query(await readFile(join(migrationsDirectory, file), "utf8"));
      await client.query("INSERT INTO schema_migrations (version) VALUES ($1)", [version]);
      applied.push(version);
    }
    await client.query("COMMIT");
    return [...applied];
  } catch (error) {
    try {
      await client.query("ROLLBACK");
    } catch {
      // The original migration error is more useful to the caller.
    }
    throw error;
  } finally {
    client.release();
  }
}

const invokedFile = process.argv[1] ? pathToFileURL(process.argv[1]).href : "";
if (invokedFile === import.meta.url) {
  runMigrations()
    .then((applied) => {
      console.log(`Applied ${applied.length} migration${applied.length === 1 ? "" : "s"}.`);
    })
    .catch((error: unknown) => {
      console.error("Database migration failed:", error);
      process.exitCode = 1;
    });
}
