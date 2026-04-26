/**
 * Shared conformance test suite for CatRepository implementations.
 *
 * Any adapter implementing CatRepository must pass these tests. This ensures
 * the in-memory adapter and the Postgres adapter conform to the same contract.
 *
 * Includes behavioral tests (save, find, delete, duplicate rejection) AND
 * observability tests (every method must produce a span with correct name and
 * semantic attributes).
 *
 * Usage:
 *   describeCatRepositoryConformance('Memory', {
 *     factory: () => new CatRepositoryMemory(),
 *     getSpans: () => testObs.getSpans(),
 *     resetSpans: () => testObs.reset(),
 *     expectedDbSystem: 'memory',
 *   });
 *
 * Pattern: future repositories (DogRepository, etc.) should follow the same approach —
 * a shared conformance suite that any adapter implementation must satisfy.
 */
import { randomUUID } from 'node:crypto';
import type { ReadableSpan } from '@opentelemetry/sdk-trace-base';
import { beforeEach, describe, expect, it } from 'vitest';
import type { CatRepository } from '../../src/adapters/cat-repository.js';
import type { Cat } from '../../src/domain/cat.js';
import { CatAlreadyExistsError } from '../../src/errors/cat-already-exists.error.js';

interface ConformanceOptions {
  /** Factory that returns a CatRepository instance. Called once before the suite. */
  factory: () => CatRepository | Promise<CatRepository>;
  /** Called before each test to reset state (e.g., truncate tables). Not needed for in-memory. */
  resetState?: () => Promise<void>;
  /** Returns all finished spans since last reset. Required for span assertions. */
  getSpans: () => ReadableSpan[];
  /** Resets the span exporter. Called before each test. */
  resetSpans: () => void;
  /** Expected value of `db.system` attribute (e.g., 'postgresql' or 'memory'). */
  expectedDbSystem: string;
}

export function describeCatRepositoryConformance(name: string, options: ConformanceOptions) {
  describe(`CatRepository conformance — ${name}`, () => {
    let repo: CatRepository;

    beforeEach(async () => {
      if (options.resetState) {
        await options.resetState();
      }
      options.resetSpans();
      repo = await options.factory();
    });

    // --- Behavioral tests ---

    it('saves and finds a cat by ID', async () => {
      const cat = makeCat({ name: 'Whiskers' });
      await repo.save(cat);

      const found = await repo.findById(cat.id);
      expect(found).toBeDefined();
      expect(found?.id).toBe(cat.id);
      expect(found?.name).toBe(cat.name);
    });

    it('saves and finds a cat by name', async () => {
      const cat = makeCat({ name: 'Luna' });
      await repo.save(cat);

      const found = await repo.findByName('Luna');
      expect(found).toBeDefined();
      expect(found?.id).toBe(cat.id);
    });

    it('returns undefined for non-existent ID', async () => {
      const found = await repo.findById(randomUUID());
      expect(found).toBeUndefined();
    });

    it('returns undefined for non-existent name', async () => {
      const found = await repo.findByName('Ghost');
      expect(found).toBeUndefined();
    });

    it('deletes a cat by ID', async () => {
      const cat = makeCat({ name: 'DeleteMe' });
      await repo.save(cat);

      const deleted = await repo.deleteById(cat.id);
      expect(deleted).toBe(true);

      const found = await repo.findById(cat.id);
      expect(found).toBeUndefined();
    });

    it('returns false when deleting a non-existent cat', async () => {
      const deleted = await repo.deleteById(randomUUID());
      expect(deleted).toBe(false);
    });

    it('rejects duplicate names with CatAlreadyExistsError', async () => {
      const name = 'DuplicateCat';
      await repo.save(makeCat({ name }));

      await expect(repo.save(makeCat({ name }))).rejects.toThrow(CatAlreadyExistsError);
    });

    // --- Span emission tests ---

    it('save emits a db.cats.save span with correct attributes', async () => {
      const cat = makeCat({ name: 'SpanCat' });
      await repo.save(cat);

      const span = findSpan(options.getSpans(), 'db.cats.save');
      expect(span).toBeDefined();
      expect(span?.attributes['db.system']).toBe(options.expectedDbSystem);
      expect(span?.attributes['db.operation.name']).toBe('INSERT');
      expect(span?.attributes['db.collection.name']).toBe('cats');
    });

    it('findById emits a db.cats.findById span with correct attributes', async () => {
      await repo.findById(randomUUID());

      const span = findSpan(options.getSpans(), 'db.cats.findById');
      expect(span).toBeDefined();
      expect(span?.attributes['db.system']).toBe(options.expectedDbSystem);
      expect(span?.attributes['db.operation.name']).toBe('SELECT');
      expect(span?.attributes['db.collection.name']).toBe('cats');
    });

    it('findByName emits a db.cats.findByName span with correct attributes', async () => {
      await repo.findByName('Ghost');

      const span = findSpan(options.getSpans(), 'db.cats.findByName');
      expect(span).toBeDefined();
      expect(span?.attributes['db.system']).toBe(options.expectedDbSystem);
      expect(span?.attributes['db.operation.name']).toBe('SELECT');
      expect(span?.attributes['db.collection.name']).toBe('cats');
    });

    it('deleteById emits a db.cats.deleteById span with correct attributes', async () => {
      await repo.deleteById(randomUUID());

      const span = findSpan(options.getSpans(), 'db.cats.deleteById');
      expect(span).toBeDefined();
      expect(span?.attributes['db.system']).toBe(options.expectedDbSystem);
      expect(span?.attributes['db.operation.name']).toBe('DELETE');
      expect(span?.attributes['db.collection.name']).toBe('cats');
    });

    it('save records exception on span when duplicate name', async () => {
      const name = 'SpanErrorCat';
      await repo.save(makeCat({ name }));
      options.resetSpans();

      try {
        await repo.save(makeCat({ name }));
      } catch {
        // expected
      }

      const span = findSpan(options.getSpans(), 'db.cats.save');
      expect(span).toBeDefined();
      expect(span?.status.code).toBe(2); // SpanStatusCode.ERROR = 2
      expect(span?.events.some((e) => e.name === 'exception')).toBe(true);
    });
  });
}

/** Helper to create a Cat with sensible defaults. */
function makeCat(overrides: Partial<Cat> = {}): Cat {
  return {
    id: randomUUID(),
    name: 'DefaultCat',
    createdAt: new Date(),
    ...overrides,
  };
}

/** Find a span by name in the finished spans array. */
function findSpan(spans: ReadableSpan[], name: string): ReadableSpan | undefined {
  return spans.find((s) => s.name === name);
}
