import { Kysely, PostgresDialect } from 'kysely';
import pg from 'pg';
import type { DB } from './db-types.generated.js';

export type Database = Kysely<DB>;

export function createDatabase(connectionString: string): Database {
  return new Kysely<DB>({
    dialect: new PostgresDialect({
      pool: new pg.Pool({ connectionString }),
    }),
  });
}
