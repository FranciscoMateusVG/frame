import { cpSync } from 'node:fs';
import { defineConfig } from 'tsup';

export default defineConfig({
  entry: ['infra/ttp/fake-upstream.ts'],
  format: ['esm'],
  platform: 'node',
  target: 'node24',
  outDir: 'dist/ttp',
  outExtension: () => ({ js: '.mjs' }),
  noExternal: [/.*/],
  splitting: false,
  sourcemap: false,
  clean: true,
  onSuccess: async () => {
    cpSync('infra/ttp/contracts', 'dist/ttp/contracts', { recursive: true });
  },
});
