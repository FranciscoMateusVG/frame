/**
 * Shared conformance test suite for CatRepository implementations.
 *
 * Any adapter implementing CatRepository must pass these tests. This ensures
 * the in-memory adapter and the Postgres adapter conform to the same contract.
 *
 * Usage:
 *   describeCatRepositoryConformance('Memory', {
 *     factory: () => new CatRepositoryMemory(),
 *   });
 *
 * Pattern: future repositories (DogRepository, etc.) should follow the same approach —
 * a shared conformance suite that any adapter implementation must satisfy.
 */
import { randomUUID } from 'node:crypto';
import { beforeEach, describe, expect, it } from 'vitest';
import type { CatRepository } from '../../src/adapters/cat-repository.js';
import type { Cat } from '../../src/domain/cat.js';
import { CatAlreadyExistsError } from '../../src/errors/cat-already-exists.error.js';

interface ConformanceOptions {
  /** Factory that returns a CatRepository instance. Called once before the suite. */
  factory: () => CatRepository | Promise<CatRepository>;
  /** Called before each test to reset state (e.g., truncate tables). Not needed for in-memory. */
  resetState?: () => Promise<void>;
}

export function describeCatRepositoryConformance(name: string, options: ConformanceOptions) {
  describe(`CatRepository conformance — ${name}`, () => {
    let repo: CatRepository;

    beforeEach(async () => {
      if (options.resetState) {
        await options.resetState();
      }
      repo = await options.factory();
    });

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
