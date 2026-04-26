import { SpanStatusCode, trace } from '@opentelemetry/api';
import type { Cat, CatId, CatName } from '../domain/cat.js';
import { CatAlreadyExistsError } from '../errors/cat-already-exists.error.js';
import type { CatRepository } from './cat-repository.js';
import type { Database } from './database.js';

const tracer = trace.getTracer('frame');

/** Shared span attributes for all Postgres cat repository operations. */
const DB_ATTRS = {
  'db.system': 'postgresql',
  'db.collection.name': 'cats',
} as const;

/**
 * PostgreSQL CatRepository implementation using Kysely.
 * Concrete adapter — not exported from the public API surface.
 *
 * Instrumented: every method wraps in a span named `db.cats.<method>` with
 * OTel semantic convention attributes. Spans nest automatically under the
 * active parent (e.g., a `createCat` use-case span) via OTel's
 * AsyncLocalStorage-backed context propagation.
 *
 * Adapters emit spans only — they do not log. Spans carry operation name,
 * attributes, and exceptions via recordException. Logging is a use-case concern.
 */
export class CatRepositoryPostgres implements CatRepository {
  constructor(private readonly db: Database) {}

  async save(cat: Cat): Promise<void> {
    return tracer.startActiveSpan('db.cats.save', async (span) => {
      span.setAttributes({ ...DB_ATTRS, 'db.operation.name': 'INSERT' });
      try {
        await this.db
          .insertInto('cats')
          .values({
            id: cat.id,
            name: cat.name,
            created_at: cat.createdAt,
          })
          .execute();
        span.setStatus({ code: SpanStatusCode.OK });
      } catch (error: unknown) {
        span.recordException(error as Error);
        span.setStatus({ code: SpanStatusCode.ERROR });
        if (isUniqueViolation(error)) {
          throw new CatAlreadyExistsError(cat.name);
        }
        throw error;
      } finally {
        span.end();
      }
    });
  }

  async findById(id: CatId): Promise<Cat | undefined> {
    return tracer.startActiveSpan('db.cats.findById', async (span) => {
      span.setAttributes({ ...DB_ATTRS, 'db.operation.name': 'SELECT' });
      try {
        const row = await this.db
          .selectFrom('cats')
          .selectAll()
          .where('id', '=', id)
          .executeTakeFirst();
        span.setStatus({ code: SpanStatusCode.OK });
        return row ? toCat(row) : undefined;
      } catch (error: unknown) {
        span.recordException(error as Error);
        span.setStatus({ code: SpanStatusCode.ERROR });
        throw error;
      } finally {
        span.end();
      }
    });
  }

  async findByName(name: CatName): Promise<Cat | undefined> {
    return tracer.startActiveSpan('db.cats.findByName', async (span) => {
      span.setAttributes({ ...DB_ATTRS, 'db.operation.name': 'SELECT' });
      try {
        const row = await this.db
          .selectFrom('cats')
          .selectAll()
          .where('name', '=', name)
          .executeTakeFirst();
        span.setStatus({ code: SpanStatusCode.OK });
        return row ? toCat(row) : undefined;
      } catch (error: unknown) {
        span.recordException(error as Error);
        span.setStatus({ code: SpanStatusCode.ERROR });
        throw error;
      } finally {
        span.end();
      }
    });
  }

  async deleteById(id: CatId): Promise<boolean> {
    return tracer.startActiveSpan('db.cats.deleteById', async (span) => {
      span.setAttributes({ ...DB_ATTRS, 'db.operation.name': 'DELETE' });
      try {
        const result = await this.db.deleteFrom('cats').where('id', '=', id).executeTakeFirst();
        span.setStatus({ code: SpanStatusCode.OK });
        return result.numDeletedRows > 0n;
      } catch (error: unknown) {
        span.recordException(error as Error);
        span.setStatus({ code: SpanStatusCode.ERROR });
        throw error;
      } finally {
        span.end();
      }
    });
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
