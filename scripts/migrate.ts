import { promises as fs } from 'node:fs';
import path from 'node:path';
import { FileMigrationProvider, Kysely, Migrator, PostgresDialect } from 'kysely';
import pg from 'pg';

const databaseUrl = process.env.DATABASE_URL ?? 'postgresql://frame:frame@localhost:54320/frame';

const db = new Kysely({
  dialect: new PostgresDialect({
    pool: new pg.Pool({ connectionString: databaseUrl }),
  }),
});

const migrator = new Migrator({
  db,
  provider: new FileMigrationProvider({
    fs,
    path,
    migrationFolder: path.join(import.meta.dirname, '..', 'migrations'),
  }),
});

const { error, results } = await migrator.migrateToLatest();

for (const result of results ?? []) {
  if (result.status === 'Success') {
    console.log(`✅ Migration "${result.migrationName}" applied successfully.`);
  } else if (result.status === 'Error') {
    console.error(`❌ Migration "${result.migrationName}" failed.`);
  }
}

if (error) {
  console.error('Migration failed:', error);
  await db.destroy();
  process.exit(1);
}

console.log('✅ All migrations applied.');
await db.destroy();
