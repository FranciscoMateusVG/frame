import type { Cat, CatId, CatName } from '../domain/cat.js';

/**
 * CatRepository — the port (interface) for cat persistence.
 * Implementations live in separate files (e.g., cat-repository.postgres.ts).
 */
export interface CatRepository {
  /** Save a new cat. Throws if a cat with the same name already exists. */
  save(cat: Cat): Promise<void>;

  /** Find a cat by its ID. Returns undefined if not found. */
  findById(id: CatId): Promise<Cat | undefined>;

  /** Find a cat by its name. Returns undefined if not found. */
  findByName(name: CatName): Promise<Cat | undefined>;

  /** Delete a cat by its ID. Returns true if deleted, false if not found. */
  deleteById(id: CatId): Promise<boolean>;
}
