/**
 * Testcontainers helper — spins up a Postgres 16 container,
 * runs migrations, and returns a connected Kysely instance.
 *
 * Used by integration tests and examples for fully self-contained execution.
 */

import { promises as fs } from 'node:fs';
import path from 'node:path';
import { PostgreSqlContainer, type StartedPostgreSqlContainer } from '@testcontainers/postgresql';
import { FileMigrationProvider, Migrator } from 'kysely';
import type { Database } from '../../src/adapters/database.js';
import { createDatabase } from '../../src/adapters/database.js';

export interface TestDatabase {
  db: Database;
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

  // Use createDatabase() — the same factory consumers use.
  // This ensures database.ts gets coverage through every integration test.
  const db = createDatabase(connectionUri);

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
