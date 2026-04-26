// --- Domain ---

// --- Adapter Interfaces (public contract — implement your own) ---
export type { CatRepository } from './adapters/cat-repository.js';
export type { Database } from './adapters/database.js';
// --- Database utilities ---
export { createDatabase } from './adapters/database.js';
export type { Cat, CatId, CatName, CreateCatInput } from './domain/cat.js';
export { CatIdSchema, CatNameSchema, CreateCatInputSchema } from './domain/cat.js';

// --- Errors ---
export { CatAlreadyExistsError } from './errors/cat-already-exists.error.js';
export { InvalidCatNameError } from './errors/invalid-cat-name.error.js';
export type { CreateCatDeps } from './use-cases/create-cat.js';
// --- Use Cases ---
export { createCat } from './use-cases/create-cat.js';
