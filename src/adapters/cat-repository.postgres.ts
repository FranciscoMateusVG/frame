import type { Cat, CatId, CatName } from '../domain/cat.js';
import { CatAlreadyExistsError } from '../errors/cat-already-exists.error.js';
import type { CatRepository } from './cat-repository.js';
import type { Database } from './database.js';

/**
 * PostgreSQL CatRepository implementation using Kysely.
 * Concrete adapter — not exported from the public API surface.
 */
export class CatRepositoryPostgres implements CatRepository {
  constructor(private readonly db: Database) {}

  async save(cat: Cat): Promise<void> {
    try {
      await this.db
        .insertInto('cats')
        .values({
          id: cat.id,
          name: cat.name,
          created_at: cat.createdAt,
        })
        .execute();
    } catch (error: unknown) {
      // PostgreSQL unique violation error code: 23505
      if (isUniqueViolation(error)) {
        throw new CatAlreadyExistsError(cat.name);
      }
      throw error;
    }
  }

  async findById(id: CatId): Promise<Cat | undefined> {
    const row = await this.db
      .selectFrom('cats')
      .selectAll()
      .where('id', '=', id)
      .executeTakeFirst();

    return row ? toCat(row) : undefined;
  }

  async findByName(name: CatName): Promise<Cat | undefined> {
    const row = await this.db
      .selectFrom('cats')
      .selectAll()
      .where('name', '=', name)
      .executeTakeFirst();

    return row ? toCat(row) : undefined;
  }

  async deleteById(id: CatId): Promise<boolean> {
    const result = await this.db.deleteFrom('cats').where('id', '=', id).executeTakeFirst();

    return result.numDeletedRows > 0n;
  }
}

function toCat(row: { id: string; name: string; created_at: Date }): Cat {
  return {
    id: row.id,
    name: row.name,
    createdAt: row.created_at,
  };
}

function isUniqueViolation(error: unknown): boolean {
  return (
    typeof error === 'object' &&
    error !== null &&
    'code' in error &&
    (error as { code: string }).code === '23505'
  );
}
