import { z } from 'zod/v4';

// --- Value Objects ---

/**
 * Cat ID — a UUID v4 string.
 * Validated at external boundaries only.
 */
export const CatIdSchema = z.uuid();
export type CatId = string;

/**
 * Cat Name — a non-empty string, max 100 characters.
 * Validated at external boundaries only.
 */
export const CatNameSchema = z
  .string()
  .trim()
  .min(1, 'Cat name must not be empty')
  .max(100, 'Cat name must be 100 characters or fewer');
export type CatName = string;

// --- Entity ---

/**
 * Cat entity — the core domain type.
 * Pure data, no methods, no I/O.
 */
export interface Cat {
  readonly id: CatId;
  readonly name: CatName;
  readonly createdAt: Date;
}

// --- Input types ---

/**
 * Input for creating a new Cat.
 * Validated at external boundaries before reaching use cases.
 */
export const CreateCatInputSchema = z.object({
  id: CatIdSchema,
  name: CatNameSchema,
});

export type CreateCatInput = z.infer<typeof CreateCatInputSchema>;
