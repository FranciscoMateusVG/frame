import { randomUUID } from 'node:crypto';
import { beforeEach, describe, expect, it } from 'vitest';
import { CatRepositoryMemory } from '../../src/adapters/cat-repository.memory.js';
import { CatAlreadyExistsError } from '../../src/errors/cat-already-exists.error.js';
import { InvalidCatNameError } from '../../src/errors/invalid-cat-name.error.js';
import { createCat } from '../../src/use-cases/create-cat.js';

describe('createCat', () => {
  let catRepository: CatRepositoryMemory;

  beforeEach(() => {
    catRepository = new CatRepositoryMemory();
  });

  it('should create a cat with valid input', async () => {
    const input = { id: randomUUID(), name: 'Whiskers' };
    const cat = await createCat({ catRepository }, input);

    expect(cat.id).toBe(input.id);
    expect(cat.name).toBe('Whiskers');
    expect(cat.createdAt).toBeInstanceOf(Date);
  });

  it('should persist the cat in the repository', async () => {
    const input = { id: randomUUID(), name: 'Luna' };
    const cat = await createCat({ catRepository }, input);

    const fetched = await catRepository.findById(cat.id);
    expect(fetched).toBeDefined();
    expect(fetched?.name).toBe('Luna');
  });

  it('should throw CatAlreadyExistsError for duplicate names', async () => {
    const name = 'Mittens';
    await createCat({ catRepository }, { id: randomUUID(), name });

    await expect(createCat({ catRepository }, { id: randomUUID(), name })).rejects.toThrow(
      CatAlreadyExistsError,
    );
  });

  it('should throw InvalidCatNameError for empty name', async () => {
    await expect(createCat({ catRepository }, { id: randomUUID(), name: '' })).rejects.toThrow(
      InvalidCatNameError,
    );
  });

  it('should throw InvalidCatNameError for name exceeding 100 characters', async () => {
    const longName = 'a'.repeat(101);
    await expect(
      createCat({ catRepository }, { id: randomUUID(), name: longName }),
    ).rejects.toThrow(InvalidCatNameError);
  });

  it('should throw InvalidCatNameError for invalid UUID', async () => {
    await expect(
      createCat({ catRepository }, { id: 'not-a-uuid', name: 'Valid Name' }),
    ).rejects.toThrow(InvalidCatNameError);
  });

  it('should trim whitespace from cat name', async () => {
    const input = { id: randomUUID(), name: '  Whiskers  ' };
    const cat = await createCat({ catRepository }, input);

    expect(cat.name).toBe('Whiskers');
  });

  it('should accept a name at exactly 100 characters', async () => {
    const name = 'a'.repeat(100);
    const cat = await createCat({ catRepository }, { id: randomUUID(), name });

    expect(cat.name).toBe(name);
  });
});
