import { afterAll } from 'vitest';
import { PrintApiMemory } from '../../src/adapters/print-api.memory.js';
import { createTestObservability } from '../helpers/observability.js';
import { describePrintApiConformance } from '../helpers/print-api.conformance.js';

const obs = createTestObservability();
afterAll(() => obs.shutdown());

describePrintApiConformance('Memory', {
  factory: async () => {
    const staff = new PrintApiMemory();
    return { api: staff, staff };
  },
  getSpans: () => obs.getSpans(),
  resetSpans: () => obs.reset(),
  expectedServerAddress: () => 'memory',
});
