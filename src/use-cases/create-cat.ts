import { SpanStatusCode } from '@opentelemetry/api';
import type { CatRepository } from '../adapters/cat-repository.js';
import type { Cat, CreateCatInput } from '../domain/cat.js';
import { CreateCatInputSchema } from '../domain/cat.js';
import { InvalidCatNameError } from '../errors/invalid-cat-name.error.js';
import type { Observability } from '../observability/observability.js';

/**
 * Dependencies required by the createCat use case.
 * Passed explicitly as the first argument — no DI container, no magic.
 *
 * This is the template every future use case copies.
 */
export interface CreateCatDeps {
  readonly catRepository: CatRepository;
  readonly clock: () => Date;
  readonly observability: Observability;
}

/**
 * Create a new Cat.
 *
 * Pure function: takes dependencies and input, returns the created Cat.
 * Validates input at the boundary, delegates persistence to the repository.
 *
 * **IDs are caller-provided** to support idempotent retries and composability
 * with related entities. Callers should generate UUIDs (e.g., `crypto.randomUUID()`)
 * and may safely retry `createCat` with the same ID — duplicate creates are caught
 * by the repository's unique constraint on name and surfaced as `CatAlreadyExistsError`.
 * Malformed IDs are caught by input validation and surfaced as `InvalidCatNameError`.
 *
 * **Instrumented:** wraps in a `createCat` span. On success, logs `cat.created`.
 * On failure, records the exception on the span and sets ERROR status.
 *
 * @throws {InvalidCatNameError} if the input fails validation (including malformed IDs)
 * @throws {CatAlreadyExistsError} if a cat with the same name already exists (from repository)
 */
export async function createCat(deps: CreateCatDeps, input: CreateCatInput): Promise<Cat> {
  const { catRepository, clock, observability } = deps;
  const { logger, tracer } = observability;

  return tracer.startActiveSpan('createCat', async (span) => {
    try {
      // Validate at the boundary
      const parsed = CreateCatInputSchema.safeParse(input);
      if (!parsed.success) {
        const message = parsed.error.issues.map((i) => i.message).join('; ');
        throw new InvalidCatNameError(message);
      }

      // Non-PII span attributes — capture shapes, not raw values
      span.setAttribute('cat.id', parsed.data.id);
      span.setAttribute('cat.name.length', parsed.data.name.length);

      const cat: Cat = {
        id: parsed.data.id,
        name: parsed.data.name,
        createdAt: clock(),
      };

      await catRepository.save(cat);

      logger.info('cat.created', {
        catId: cat.id,
        nameLength: cat.name.length,
      });

      span.setStatus({ code: SpanStatusCode.OK });
      return cat;
    } catch (error) {
      span.recordException(error as Error);
      span.setStatus({ code: SpanStatusCode.ERROR, message: (error as Error).message });
      throw error;
    } finally {
      span.end();
    }
  });
}
