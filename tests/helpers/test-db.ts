/**
 * Testcontainers helper — spins up a Postgres 16 container,
 * runs migrations, and returns a connected Kysely instance.
 *
 * Used by integration tests and examples for fully self-contained execution.
 */

import { promises as fs } from 'node:fs';
import path from 'node:path';
import { PostgreSqlContainer, type StartedPostgreSqlContainer } from '@testcontainers/postgresql';
import { FileMigrationProvider, Kysely, Migrator, PostgresDialect } from 'kysely';
import pg from 'pg';
import type { DB } from '../../src/adapters/db-types.generated.js';

export interface TestDatabase {
  db: Kysely<DB>;
  connectionUri: string;
  container: StartedPostgreSqlContainer;
  teardown: () => Promise<void>;
}

export async function createTestDatabase(): Promise<TestDatabase> {
  const container = await new PostgreSqlContainer('postgres:16')
    .withDatabase('frame')
    .withUsername('frame')
    .withPassword('frame')
    .start();

  const connectionUri = container.getConnectionUri();

  const pool = new pg.Pool({ connectionString: connectionUri });
  const db = new Kysely<DB>({
    dialect: new PostgresDialect({ pool }),
  });

  // Run migrations
  const migrator = new Migrator({
    db,
    provider: new FileMigrationProvider({
      fs,
      path,
      migrationFolder: path.join(import.meta.dirname, '..', '..', 'migrations'),
    }),
  });

  const { error } = await migrator.migrateToLatest();
  if (error) {
    await db.destroy();
    await container.stop();
    throw new Error(`Migration failed: ${String(error)}`);
  }

  const teardown = async () => {
    await db.destroy();
    await container.stop();
  };

  return { db, connectionUri, container, teardown };
}
