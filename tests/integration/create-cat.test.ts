/**
 * Integration tests for the createCat use case.
 *
 * These are the primary behavioral spec for createCat. They run against a real
 * Postgres database via Testcontainers. Named as specs — what the use case does,
 * not how it's implemented.
 *
 * Test isolation: beforeEach truncates the cats table. Testcontainers provides
 * a fresh DB per suite. Any test can run independently in any order.
 */
import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { CatRepositoryPostgres } from '../../src/adapters/cat-repository.postgres.js';
import { CatAlreadyExistsError } from '../../src/errors/cat-already-exists.error.js';
import { InvalidCatNameError } from '../../src/errors/invalid-cat-name.error.js';
import { createCat } from '../../src/use-cases/create-cat.js';
import { createTestDatabase, type TestDatabase } from '../helpers/test-db.js';

let testDb: TestDatabase;
let catRepository: CatRepositoryPostgres;

beforeAll(async () => {
  testDb = await createTestDatabase();
}, 60000);

afterAll(async () => {
  await testDb.teardown();
});

beforeEach(async () => {
  // Truncate between tests for full isolation.
  // Pattern: every integration test file should truncate relevant tables in beforeEach.
  await testDb.db.deleteFrom('cats').execute();
  catRepository = new CatRepositoryPostgres(testDb.db);
});

describe('createCat', () => {
  // --- Happy path ---

  it('creates a cat with the given name', async () => {
    const id = randomUUID();
    const cat = await createCat({ catRepository }, { id, name: 'Whiskers' });

    expect(cat.id).toBe(id);
    expect(cat.name).toBe('Whiskers');
    expect(cat.createdAt).toBeInstanceOf(Date);
  });

  it('persists the cat so it can be found by ID', async () => {
    const id = randomUUID();
    await createCat({ catRepository }, { id, name: 'Luna' });

    const found = await catRepository.findById(id);
    expect(found).toBeDefined();
    expect(found?.name).toBe('Luna');
  });

  it('persists the cat so it can be found by name', async () => {
    await createCat({ catRepository }, { id: randomUUID(), name: 'Mittens' });

    const found = await catRepository.findByName('Mittens');
    expect(found).toBeDefined();
    expect(found?.name).toBe('Mittens');
  });

  it('trims whitespace from the cat name', async () => {
    const cat = await createCat({ catRepository }, { id: randomUUID(), name: '  Whiskers  ' });

    expect(cat.name).toBe('Whiskers');
  });

  it('accepts a name at exactly 100 characters', async () => {
    const name = 'a'.repeat(100);
    const cat = await createCat({ catRepository }, { id: randomUUID(), name });

    expect(cat.name).toBe(name);
  });

  // --- Validation errors ---

  it('rejects an empty name with InvalidCatNameError', async () => {
    await expect(createCat({ catRepository }, { id: randomUUID(), name: '' })).rejects.toThrow(
      InvalidCatNameError,
    );
  });

  it('rejects a name exceeding 100 characters with InvalidCatNameError', async () => {
    const longName = 'a'.repeat(101);
    await expect(
      createCat({ catRepository }, { id: randomUUID(), name: longName }),
    ).rejects.toThrow(InvalidCatNameError);
  });

  it('rejects an invalid UUID with InvalidCatNameError', async () => {
    await expect(
      createCat({ catRepository }, { id: 'not-a-uuid', name: 'Valid Name' }),
    ).rejects.toThrow(InvalidCatNameError);
  });

  it('rejects a whitespace-only name with InvalidCatNameError', async () => {
    await expect(createCat({ catRepository }, { id: randomUUID(), name: '   ' })).rejects.toThrow(
      InvalidCatNameError,
    );
  });

  // --- Duplicate handling ---

  it('rejects a duplicate name with CatAlreadyExistsError', async () => {
    const name = 'OnlyOne';
    await createCat({ catRepository }, { id: randomUUID(), name });

    await expect(createCat({ catRepository }, { id: randomUUID(), name })).rejects.toThrow(
      CatAlreadyExistsError,
    );
  });

  it('allows creating cats with different names', async () => {
    await createCat({ catRepository }, { id: randomUUID(), name: 'Cat A' });
    const catB = await createCat({ catRepository }, { id: randomUUID(), name: 'Cat B' });

    expect(catB.name).toBe('Cat B');
  });

  // --- Idempotency (caller-provided IDs) ---

  it('rejects retrying with the same name (idempotency is name-based)', async () => {
    const name = 'Persistent';
    await createCat({ catRepository }, { id: randomUUID(), name });

    // Retry with a different ID but the same name — should fail
    await expect(createCat({ catRepository }, { id: randomUUID(), name })).rejects.toThrow(
      CatAlreadyExistsError,
    );
  });
});
