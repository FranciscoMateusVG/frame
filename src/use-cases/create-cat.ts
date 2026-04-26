import type { CatRepository } from '../adapters/cat-repository.js';
import type { Cat, CreateCatInput } from '../domain/cat.js';
import { CreateCatInputSchema } from '../domain/cat.js';
import { InvalidCatNameError } from '../errors/invalid-cat-name.error.js';

/**
 * Dependencies required by the createCat use case.
 * Passed explicitly as the first argument — no DI container, no magic.
 */
export interface CreateCatDeps {
  readonly catRepository: CatRepository;
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
 * @throws {InvalidCatNameError} if the input fails validation (including malformed IDs)
 * @throws {CatAlreadyExistsError} if a cat with the same name already exists (from repository)
 */
export async function createCat(deps: CreateCatDeps, input: CreateCatInput): Promise<Cat> {
  // Validate at the boundary
  const parsed = CreateCatInputSchema.safeParse(input);
  if (!parsed.success) {
    const message = parsed.error.issues.map((i) => i.message).join('; ');
    throw new InvalidCatNameError(message);
  }

  const cat: Cat = {
    id: parsed.data.id,
    name: parsed.data.name,
    createdAt: new Date(),
  };

  await deps.catRepository.save(cat);

  return cat;
}
