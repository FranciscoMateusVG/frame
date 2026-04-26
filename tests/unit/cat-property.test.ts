import { randomUUID } from 'node:crypto';
import fc from 'fast-check';
import { describe, expect, it } from 'vitest';
import { CatRepositoryMemory } from '../../src/adapters/cat-repository.memory.js';
import { CatNameSchema } from '../../src/domain/cat.js';
import { NoopLogger } from '../../src/observability/noop-logger.js';
import { noopTracer } from '../../src/observability/tracer.js';
import { createCat } from '../../src/use-cases/create-cat.js';

const silentObservability = {
  logger: new NoopLogger(),
  tracer: noopTracer(),
};

describe('Cat property-based tests', () => {
  it('round-trip: creating a cat then fetching it returns the same cat for any valid input', async () => {
    await fc.assert(
      fc.asyncProperty(
        fc.string({ minLength: 1, maxLength: 100 }).filter((s) => s.trim().length > 0),
        async (name) => {
          const catRepository = new CatRepositoryMemory();
          const id = randomUUID();

          const created = await createCat(
            { catRepository, clock: () => new Date(), observability: silentObservability },
            { id, name },
          );
          const fetched = await catRepository.findById(id);

          expect(fetched).toBeDefined();
          expect(fetched?.id).toBe(created.id);
          expect(fetched?.name).toBe(created.name);
          expect(fetched?.createdAt).toEqual(created.createdAt);
        },
      ),
      { numRuns: 50 },
    );
  });

  it('validation invariant: any string whose trimmed length exceeds 100 chars is rejected by CatNameSchema', () => {
    fc.assert(
      fc.property(
        fc.string({ minLength: 101, maxLength: 500 }).filter((s) => s.trim().length > 100),
        (longName) => {
          const result = CatNameSchema.safeParse(longName);
          expect(result.success).toBe(false);
        },
      ),
      { numRuns: 100 },
    );
  });

  it('validation invariant: any non-empty trimmed string within 100 chars is accepted by CatNameSchema', () => {
    fc.assert(
      fc.property(
        fc
          .string({ minLength: 1, maxLength: 100 })
          .filter((s) => s.trim().length > 0 && s.trim().length <= 100),
        (name) => {
          const result = CatNameSchema.safeParse(name);
          expect(result.success).toBe(true);
        },
      ),
      { numRuns: 100 },
    );
  });
});
