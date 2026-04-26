import { SpanStatusCode, trace } from '@opentelemetry/api';
import type { Cat, CatId, CatName } from '../domain/cat.js';
import { CatAlreadyExistsError } from '../errors/cat-already-exists.error.js';
import type { CatRepository } from './cat-repository.js';

const tracer = trace.getTracer('frame');

/** Shared span attributes for all in-memory cat repository operations. */
const DB_ATTRS = {
  'db.system': 'memory',
  'db.collection.name': 'cats',
} as const;

/**
 * In-memory CatRepository implementation.
 * Used for unit tests and examples that don't need a real database.
 *
 * Instrumented identically to the Postgres adapter: same span names,
 * same attributes (`db.system` is `"memory"` instead of `"postgresql"`).
 * The conformance suite asserts both produce equivalent spans.
 *
 * Adapters emit spans only — they do not log.
 */
export class CatRepositoryMemory implements CatRepository {
  private readonly cats = new Map<CatId, Cat>();

  async save(cat: Cat): Promise<void> {
    return tracer.startActiveSpan('db.cats.save', async (span) => {
      span.setAttributes({ ...DB_ATTRS, 'db.operation.name': 'INSERT' });
      try {
        for (const existing of this.cats.values()) {
          if (existing.name === cat.name) {
            throw new CatAlreadyExistsError(cat.name);
          }
        }
        this.cats.set(cat.id, cat);
        span.setStatus({ code: SpanStatusCode.OK });
      } catch (error: unknown) {
        span.recordException(error as Error);
        span.setStatus({ code: SpanStatusCode.ERROR });
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
        const result = this.cats.get(id);
        span.setStatus({ code: SpanStatusCode.OK });
        return result;
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
        for (const cat of this.cats.values()) {
          if (cat.name === name) {
            span.setStatus({ code: SpanStatusCode.OK });
            return cat;
          }
        }
        span.setStatus({ code: SpanStatusCode.OK });
        return undefined;
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
        const result = this.cats.delete(id);
        span.setStatus({ code: SpanStatusCode.OK });
        return result;
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
