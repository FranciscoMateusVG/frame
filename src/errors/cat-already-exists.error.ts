import type { CatName } from '../domain/cat.js';

export class CatAlreadyExistsError extends Error {
  public readonly code = 'CAT_ALREADY_EXISTS' as const;

  constructor(public readonly name: CatName) {
    super(`A cat with the name "${name}" already exists.`);
    this.name = 'CatAlreadyExistsError';
  }
}
