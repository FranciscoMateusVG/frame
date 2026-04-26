import type { Cat, CatId, CatName } from '../domain/cat.js';
import { CatAlreadyExistsError } from '../errors/cat-already-exists.error.js';
import type { CatRepository } from './cat-repository.js';

/**
 * In-memory CatRepository implementation.
 * Used for unit tests and examples that don't need a real database.
 */
export class CatRepositoryMemory implements CatRepository {
  private readonly cats = new Map<CatId, Cat>();

  async save(cat: Cat): Promise<void> {
    // Check uniqueness constraint on name
    for (const existing of this.cats.values()) {
      if (existing.name === cat.name) {
        throw new CatAlreadyExistsError(cat.name);
      }
    }
    this.cats.set(cat.id, cat);
  }

  async findById(id: CatId): Promise<Cat | undefined> {
    return this.cats.get(id);
  }

  async findByName(name: CatName): Promise<Cat | undefined> {
    for (const cat of this.cats.values()) {
      if (cat.name === name) {
        return cat;
      }
    }
    return undefined;
  }

  async deleteById(id: CatId): Promise<boolean> {
    return this.cats.delete(id);
  }
}
