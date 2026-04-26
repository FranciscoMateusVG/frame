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
 * @throws {InvalidCatNameError} if the input fails validation
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
