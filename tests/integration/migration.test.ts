import { promises as fs } from 'node:fs';
import path from 'node:path';
import { PostgreSqlContainer, type StartedPostgreSqlContainer } from '@testcontainers/postgresql';
import { FileMigrationProvider, Kysely, Migrator, PostgresDialect } from 'kysely';
import pg from 'pg';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

describe('Migration round-trip', () => {
  let container: StartedPostgreSqlContainer;
  let db: Kysely<unknown>;

  beforeAll(async () => {
    container = await new PostgreSqlContainer('postgres:16')
      .withDatabase('frame')
      .withUsername('frame')
      .withPassword('frame')
      .start();

    db = new Kysely({
      dialect: new PostgresDialect({
        pool: new pg.Pool({ connectionString: container.getConnectionUri() }),
      }),
    });
  }, 60000);

  afterAll(async () => {
    await db.destroy();
    await container.stop();
  });

  it('should migrate up and down cleanly', async () => {
    const migrator = new Migrator({
      db,
      provider: new FileMigrationProvider({
        fs,
        path,
        migrationFolder: path.join(import.meta.dirname, '..', '..', 'migrations'),
      }),
    });

    // Migrate up
    const upResult = await migrator.migrateToLatest();
    expect(upResult.error).toBeUndefined();
    expect(upResult.results).toBeDefined();
    expect(upResult.results?.every((r) => r.status === 'Success')).toBe(true);

    // Verify cats table exists
    const tables = await db
      .selectFrom('information_schema.tables' as never)
      .select('table_name' as never)
      .where('table_schema' as never, '=', 'public')
      .execute();
    const tableNames = tables.map((t: Record<string, unknown>) => t.table_name);
    expect(tableNames).toContain('cats');

    // Migrate down
    const downResult = await migrator.migrateDown();
    expect(downResult.error).toBeUndefined();

    // Verify cats table is gone
    const tablesAfter = await db
      .selectFrom('information_schema.tables' as never)
      .select('table_name' as never)
      .where('table_schema' as never, '=', 'public')
      .execute();
    const tableNamesAfter = tablesAfter.map((t: Record<string, unknown>) => t.table_name);
    expect(tableNamesAfter).not.toContain('cats');
  });
});
