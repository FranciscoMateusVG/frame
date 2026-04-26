/**
 * Postgres adapter conformance + Postgres-specific behavior tests.
 *
 * The conformance suite (shared with the in-memory adapter) covers the core
 * contract: save, find, delete, duplicate rejection, AND span emission.
 * This file adds Postgres-specific tests: concurrency behavior under real
 * database constraints.
 *
 * Test isolation: beforeEach truncates the cats table, ensuring any test can
 * run in isolation and in any order. Testcontainers provides a fresh DB per suite.
 */
import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { CatRepositoryPostgres } from '../../src/adapters/cat-repository.postgres.js';
import { CatAlreadyExistsError } from '../../src/errors/cat-already-exists.error.js';
import { describeCatRepositoryConformance } from '../helpers/cat-repository.conformance.js';
import { createTestObservability } from '../helpers/observability.js';
import { createTestDatabase, type TestDatabase } from '../helpers/test-db.js';

let testDb: TestDatabase;
const testObs = createTestObservability();

beforeAll(async () => {
  testDb = await createTestDatabase();
}, 60000);

afterAll(async () => {
  await testDb.teardown();
  await testObs.shutdown();
});

/**
 * Conformance suite — same tests that run against the in-memory adapter.
 * Proves the Postgres adapter satisfies the same CatRepository contract,
 * including span emission with correct attributes.
 */
describeCatRepositoryConformance('Postgres', {
  factory: () => new CatRepositoryPostgres(testDb.db),
  resetState: async () => {
    // Truncate between tests for full isolation.
    await testDb.db.deleteFrom('cats').execute();
  },
  getSpans: () => testObs.getSpans(),
  resetSpans: () => testObs.reset(),
  expectedDbSystem: 'postgresql',
});

/**
 * Postgres-specific tests — behavior that only matters with a real database.
 */
describe('CatRepositoryPostgres — Postgres-specific', () => {
  let repo: CatRepositoryPostgres;

  beforeEach(async () => {
    await testDb.db.deleteFrom('cats').execute();
    testObs.reset();
    repo = new CatRepositoryPostgres(testDb.db);
  });

  it('concurrency: two simultaneous saves with same name — one succeeds, one fails', async () => {
    const name = 'ConcurrentCat';
    const cat1 = { id: randomUUID(), name, createdAt: new Date() };
    const cat2 = { id: randomUUID(), name, createdAt: new Date() };

    const results = await Promise.allSettled([repo.save(cat1), repo.save(cat2)]);

    const successes = results.filter((r) => r.status === 'fulfilled');
    const failures = results.filter((r) => r.status === 'rejected');

    expect(successes).toHaveLength(1);
    expect(failures).toHaveLength(1);

    const failure = failures[0] as PromiseRejectedResult;
    expect(failure.reason).toBeInstanceOf(CatAlreadyExistsError);
  });
});
