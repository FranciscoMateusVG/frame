import { describe, expect, it } from 'vitest';
import { CatIdSchema, CatNameSchema, CreateCatInputSchema } from '../../src/domain/cat.js';

describe('CatNameSchema', () => {
  it('should accept a valid name', () => {
    const result = CatNameSchema.safeParse('Whiskers');
    expect(result.success).toBe(true);
  });

  it('should reject an empty string', () => {
    const result = CatNameSchema.safeParse('');
    expect(result.success).toBe(false);
  });

  it('should reject a name over 100 characters', () => {
    const result = CatNameSchema.safeParse('a'.repeat(101));
    expect(result.success).toBe(false);
  });

  it('should accept a name at exactly 100 characters', () => {
    const result = CatNameSchema.safeParse('a'.repeat(100));
    expect(result.success).toBe(true);
  });

  it('should trim whitespace', () => {
    const result = CatNameSchema.safeParse('  Luna  ');
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data).toBe('Luna');
    }
  });

  it('should accept single-character name', () => {
    const result = CatNameSchema.safeParse('X');
    expect(result.success).toBe(true);
  });

  it('should reject whitespace-only string (trims to empty)', () => {
    const result = CatNameSchema.safeParse('   ');
    expect(result.success).toBe(false);
  });
});

describe('CatIdSchema', () => {
  it('should accept a valid UUID v4', () => {
    const result = CatIdSchema.safeParse('550e8400-e29b-41d4-a716-446655440000');
    expect(result.success).toBe(true);
  });

  it('should reject an invalid string', () => {
    const result = CatIdSchema.safeParse('not-a-uuid');
    expect(result.success).toBe(false);
  });

  it('should reject an empty string', () => {
    const result = CatIdSchema.safeParse('');
    expect(result.success).toBe(false);
  });
});

describe('CreateCatInputSchema', () => {
  it('should accept valid input', () => {
    const result = CreateCatInputSchema.safeParse({
      id: '550e8400-e29b-41d4-a716-446655440000',
      name: 'Whiskers',
    });
    expect(result.success).toBe(true);
  });

  it('should reject missing name', () => {
    const result = CreateCatInputSchema.safeParse({
      id: '550e8400-e29b-41d4-a716-446655440000',
    });
    expect(result.success).toBe(false);
  });

  it('should reject missing id', () => {
    const result = CreateCatInputSchema.safeParse({
      name: 'Whiskers',
    });
    expect(result.success).toBe(false);
  });
});
