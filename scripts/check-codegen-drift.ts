/**
 * Codegen drift check — verifies committed db-types.generated.ts matches live schema.
 *
 * Spins up a Testcontainers Postgres, runs migrations, generates types to a temp file,
 * and diffs against the committed file. Exits non-zero if they differ.
 */

import { execSync } from 'node:child_process';
import { promises as fs, readFileSync, unlinkSync } from 'node:fs';
import path, { join } from 'node:path';
import { PostgreSqlContainer } from '@testcontainers/postgresql';
import { FileMigrationProvider, Kysely, Migrator, PostgresDialect } from 'kysely';
import pg from 'pg';

const committedPath = join(import.meta.dirname, '..', 'src', 'adapters', 'db-types.generated.ts');
const tmpPath = join(import.meta.dirname, '..', 'tmp', 'db-types.drift-check.ts');

console.log('🔍 Starting codegen drift check...');

// 1. Start Testcontainers Postgres
const container = await new PostgreSqlContainer('postgres:16')
  .withDatabase('frame')
  .withUsername('frame')
  .withPassword('frame')
  .start();

const connectionUrl = container.getConnectionUri();
console.log(`   Postgres container started at ${connectionUrl}`);

try {
  // 2. Run migrations
  const db = new Kysely({
    dialect: new PostgresDialect({
      pool: new pg.Pool({ connectionString: connectionUrl }),
    }),
  });

  const migrator = new Migrator({
    db,
    provider: new FileMigrationProvider({
      fs,
      path,
      migrationFolder: join(import.meta.dirname, '..', 'migrations'),
    }),
  });

  const { error } = await migrator.migrateToLatest();
  if (error) {
    throw new Error(`Migration failed: ${error}`);
  }
  await db.destroy();
  console.log('   Migrations applied.');

  // 3. Generate types to temp file
  const tmpDir = join(import.meta.dirname, '..', 'tmp');
  execSync(`mkdir -p ${tmpDir}`);
  execSync(`pnpm exec kysely-codegen --url "${connectionUrl}" --out-file "${tmpPath}"`, {
    stdio: 'pipe',
  });
  console.log('   Types generated to temp file.');

  // 4. Compare
  const committed = readFileSync(committedPath, 'utf-8').trim();
  const generated = readFileSync(tmpPath, 'utf-8').trim();

  if (committed !== generated) {
    console.error('');
    console.error('❌ Codegen drift detected!');
    console.error('   The committed db-types.generated.ts does not match the live schema.');
    console.error('   Run `pnpm db:codegen` and commit the result.');
    console.error('');
    process.exit(1);
  }

  console.log('✅ No codegen drift. Committed types match live schema.');
} finally {
  // Cleanup
  try {
    unlinkSync(tmpPath);
  } catch {
    // ignore
  }
  await container.stop();
}
