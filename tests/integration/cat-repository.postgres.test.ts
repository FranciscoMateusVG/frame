import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { CatRepositoryPostgres } from '../../src/adapters/cat-repository.postgres.js';
import type { Cat } from '../../src/domain/cat.js';
import { CatAlreadyExistsError } from '../../src/errors/cat-already-exists.error.js';
import { createTestDatabase, type TestDatabase } from '../helpers/test-db.js';

describe('CatRepositoryPostgres', () => {
  let testDb: TestDatabase;
  let repo: CatRepositoryPostgres;

  beforeAll(async () => {
    testDb = await createTestDatabase();
    repo = new CatRepositoryPostgres(testDb.db);
  }, 60000);

  afterAll(async () => {
    await testDb.teardown();
  });

  beforeEach(async () => {
    // Clean the cats table between tests
    await testDb.db.deleteFrom('cats').execute();
  });

  it('should save and find a cat by ID', async () => {
    const cat: Cat = {
      id: randomUUID(),
      name: 'Whiskers',
      createdAt: new Date(),
    };

    await repo.save(cat);
    const found = await repo.findById(cat.id);

    expect(found).toBeDefined();
    expect(found?.id).toBe(cat.id);
    expect(found?.name).toBe(cat.name);
  });

  it('should find a cat by name', async () => {
    const cat: Cat = {
      id: randomUUID(),
      name: 'Luna',
      createdAt: new Date(),
    };

    await repo.save(cat);
    const found = await repo.findByName('Luna');

    expect(found).toBeDefined();
    expect(found?.id).toBe(cat.id);
  });

  it('should return undefined for non-existent ID', async () => {
    const found = await repo.findById(randomUUID());
    expect(found).toBeUndefined();
  });

  it('should return undefined for non-existent name', async () => {
    const found = await repo.findByName('NonExistent');
    expect(found).toBeUndefined();
  });

  it('should delete a cat by ID', async () => {
    const cat: Cat = {
      id: randomUUID(),
      name: 'DeleteMe',
      createdAt: new Date(),
    };

    await repo.save(cat);
    const deleted = await repo.deleteById(cat.id);
    expect(deleted).toBe(true);

    const found = await repo.findById(cat.id);
    expect(found).toBeUndefined();
  });

  it('should return false when deleting non-existent cat', async () => {
    const deleted = await repo.deleteById(randomUUID());
    expect(deleted).toBe(false);
  });

  it('should throw CatAlreadyExistsError for duplicate names', async () => {
    const name = 'DuplicateCat';
    const cat1: Cat = { id: randomUUID(), name, createdAt: new Date() };
    const cat2: Cat = { id: randomUUID(), name, createdAt: new Date() };

    await repo.save(cat1);
    await expect(repo.save(cat2)).rejects.toThrow(CatAlreadyExistsError);
  });

  it('concurrency: two simultaneous saves with same name — one succeeds, one fails', async () => {
    const name = 'ConcurrentCat';
    const cat1: Cat = { id: randomUUID(), name, createdAt: new Date() };
    const cat2: Cat = { id: randomUUID(), name, createdAt: new Date() };

    const results = await Promise.allSettled([repo.save(cat1), repo.save(cat2)]);

    const successes = results.filter((r) => r.status === 'fulfilled');
    const failures = results.filter((r) => r.status === 'rejected');

    expect(successes).toHaveLength(1);
    expect(failures).toHaveLength(1);

    const failure = failures[0] as PromiseRejectedResult;
    expect(failure.reason).toBeInstanceOf(CatAlreadyExistsError);
  });
});
