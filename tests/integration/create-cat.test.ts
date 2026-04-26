/**
 * Integration tests for the createCat use case.
 *
 * These are the primary behavioral spec for createCat. They run against a real
 * Postgres database via Testcontainers. Named as specs — what the use case does,
 * not how it's implemented.
 *
 * Test isolation: beforeEach truncates the cats table. Testcontainers provides
 * a fresh DB per suite. Any test can run independently in any order.
 *
 * Wave 2 additions: span emission tests verifying parent-child relationships
 * and error-path span recording.
 */
import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { CatRepositoryPostgres } from '../../src/adapters/cat-repository.postgres.js';
import { CatAlreadyExistsError } from '../../src/errors/cat-already-exists.error.js';
import { InvalidCatNameError } from '../../src/errors/invalid-cat-name.error.js';
import { createCat } from '../../src/use-cases/create-cat.js';
import { createTestObservability } from '../helpers/observability.js';
import { createTestDatabase, type TestDatabase } from '../helpers/test-db.js';

let testDb: TestDatabase;
const testObs = createTestObservability();

/** Fixed clock for deterministic timestamps in tests. */
const fixedDate = new Date('2026-01-15T12:00:00.000Z');
const clock = () => fixedDate;

/** Shared deps builder — DRY across all tests. */
function makeDeps() {
  return {
    catRepository: new CatRepositoryPostgres(testDb.db),
    clock,
    observability: testObs.observability,
  };
}

beforeAll(async () => {
  testDb = await createTestDatabase();
}, 60000);

afterAll(async () => {
  await testDb.teardown();
  await testObs.shutdown();
});

beforeEach(async () => {
  // Truncate between tests for full isolation.
  await testDb.db.deleteFrom('cats').execute();
  testObs.reset();
});

describe('createCat', () => {
  // --- Happy path ---

  it('creates a cat with the given name', async () => {
    const id = randomUUID();
    const cat = await createCat(makeDeps(), { id, name: 'Whiskers' });

    expect(cat.id).toBe(id);
    expect(cat.name).toBe('Whiskers');
    expect(cat.createdAt).toBeInstanceOf(Date);
  });

  it('uses the injected clock for createdAt', async () => {
    const cat = await createCat(makeDeps(), { id: randomUUID(), name: 'ClockCat' });

    expect(cat.createdAt).toBe(fixedDate);
  });

  it('persists the cat so it can be found by ID', async () => {
    const deps = makeDeps();
    const id = randomUUID();
    await createCat(deps, { id, name: 'Luna' });

    const found = await deps.catRepository.findById(id);
    expect(found).toBeDefined();
    expect(found?.name).toBe('Luna');
  });

  it('persists the cat so it can be found by name', async () => {
    const deps = makeDeps();
    await createCat(deps, { id: randomUUID(), name: 'Mittens' });

    const found = await deps.catRepository.findByName('Mittens');
    expect(found).toBeDefined();
    expect(found?.name).toBe('Mittens');
  });

  it('trims whitespace from the cat name', async () => {
    const cat = await createCat(makeDeps(), { id: randomUUID(), name: '  Whiskers  ' });

    expect(cat.name).toBe('Whiskers');
  });

  it('accepts a name at exactly 100 characters', async () => {
    const name = 'a'.repeat(100);
    const cat = await createCat(makeDeps(), { id: randomUUID(), name });

    expect(cat.name).toBe(name);
  });

  // --- Validation errors ---

  it('rejects an empty name with InvalidCatNameError', async () => {
    await expect(createCat(makeDeps(), { id: randomUUID(), name: '' })).rejects.toThrow(
      InvalidCatNameError,
    );
  });

  it('rejects a name exceeding 100 characters with InvalidCatNameError', async () => {
    const longName = 'a'.repeat(101);
    await expect(createCat(makeDeps(), { id: randomUUID(), name: longName })).rejects.toThrow(
      InvalidCatNameError,
    );
  });

  it('rejects an invalid UUID with InvalidCatNameError', async () => {
    await expect(createCat(makeDeps(), { id: 'not-a-uuid', name: 'Valid Name' })).rejects.toThrow(
      InvalidCatNameError,
    );
  });

  it('rejects a whitespace-only name with InvalidCatNameError', async () => {
    await expect(createCat(makeDeps(), { id: randomUUID(), name: '   ' })).rejects.toThrow(
      InvalidCatNameError,
    );
  });

  // --- Duplicate handling ---

  it('rejects a duplicate name with CatAlreadyExistsError', async () => {
    const deps = makeDeps();
    const name = 'OnlyOne';
    await createCat(deps, { id: randomUUID(), name });

    await expect(createCat(deps, { id: randomUUID(), name })).rejects.toThrow(
      CatAlreadyExistsError,
    );
  });

  it('allows creating cats with different names', async () => {
    const deps = makeDeps();
    await createCat(deps, { id: randomUUID(), name: 'Cat A' });
    const catB = await createCat(deps, { id: randomUUID(), name: 'Cat B' });

    expect(catB.name).toBe('Cat B');
  });

  // --- Idempotency (caller-provided IDs) ---

  it('rejects retrying with the same name (idempotency is name-based)', async () => {
    const deps = makeDeps();
    const name = 'Persistent';
    await createCat(deps, { id: randomUUID(), name });

    // Retry with a different ID but the same name — should fail
    await expect(createCat(deps, { id: randomUUID(), name })).rejects.toThrow(
      CatAlreadyExistsError,
    );
  });

  // --- Span emission (Wave 2) ---

  it('emits a createCat parent span containing a child db.cats.save span', async () => {
    await createCat(makeDeps(), { id: randomUUID(), name: 'SpanCat' });

    const spans = testObs.getSpans();
    const createCatSpan = spans.find((s) => s.name === 'createCat');
    const saveSpan = spans.find((s) => s.name === 'db.cats.save');

    expect(createCatSpan).toBeDefined();
    expect(saveSpan).toBeDefined();

    // Verify parent-child relationship via parentSpanContext (SDK v2 API)
    expect(saveSpan?.parentSpanContext?.spanId).toBe(createCatSpan?.spanContext().spanId);

    // Verify they share the same trace
    expect(saveSpan?.spanContext().traceId).toBe(createCatSpan?.spanContext().traceId);

    // Verify createCat span attributes
    expect(createCatSpan?.attributes['cat.name.length']).toBe(7); // 'SpanCat'.length
  });

  it('records exception on createCat span when validation fails', async () => {
    try {
      await createCat(makeDeps(), { id: randomUUID(), name: '' });
    } catch {
      // expected
    }

    const spans = testObs.getSpans();
    const createCatSpan = spans.find((s) => s.name === 'createCat');

    expect(createCatSpan).toBeDefined();
    expect(createCatSpan?.status.code).toBe(2); // SpanStatusCode.ERROR = 2
    expect(createCatSpan?.events.some((e) => e.name === 'exception')).toBe(true);
  });

  it('records exception on createCat span when duplicate name', async () => {
    const deps = makeDeps();
    await createCat(deps, { id: randomUUID(), name: 'DupSpan' });
    testObs.reset();

    try {
      await createCat(deps, { id: randomUUID(), name: 'DupSpan' });
    } catch {
      // expected
    }

    const spans = testObs.getSpans();
    const createCatSpan = spans.find((s) => s.name === 'createCat');
    const saveSpan = spans.find((s) => s.name === 'db.cats.save');

    // Both spans should record the error
    expect(createCatSpan?.status.code).toBe(2);
    expect(saveSpan?.status.code).toBe(2);

    // Both should have exception events
    expect(createCatSpan?.events.some((e) => e.name === 'exception')).toBe(true);
    expect(saveSpan?.events.some((e) => e.name === 'exception')).toBe(true);
  });
});
