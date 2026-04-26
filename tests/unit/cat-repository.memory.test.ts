import { CatRepositoryMemory } from '../../src/adapters/cat-repository.memory.js';
import { describeCatRepositoryConformance } from '../helpers/cat-repository.conformance.js';

describeCatRepositoryConformance('Memory', {
  factory: () => new CatRepositoryMemory(),
  // No resetState needed — each call to factory() creates a fresh instance with an empty Map.
});
