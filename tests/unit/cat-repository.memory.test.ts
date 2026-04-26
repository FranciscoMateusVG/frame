import { afterAll } from 'vitest';
import { CatRepositoryMemory } from '../../src/adapters/cat-repository.memory.js';
import { describeCatRepositoryConformance } from '../helpers/cat-repository.conformance.js';
import { createTestObservability } from '../helpers/observability.js';

const testObs = createTestObservability();

afterAll(async () => {
  await testObs.shutdown();
});

describeCatRepositoryConformance('Memory', {
  factory: () => new CatRepositoryMemory(),
  getSpans: () => testObs.getSpans(),
  resetSpans: () => testObs.reset(),
  expectedDbSystem: 'memory',
  // No resetState needed — each call to factory() creates a fresh instance with an empty Map.
});
