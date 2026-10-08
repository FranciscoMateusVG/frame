import { defineConfig } from 'tsup';

export default defineConfig({
  entry: {
    index: 'src/index.ts',
    'adapters/postgres': 'src/adapters/cat-repository.postgres.ts',
    testing: 'src/testing/observability.ts',
  },
  format: ['esm', 'cjs'],
  dts: {
    // tsup 8 injects baseUrl into DTS compilation; TS 6 deprecates that option.
    compilerOptions: { ignoreDeprecations: '6.0' },
  },
  sourcemap: true,
  clean: true,
  outDir: 'dist',
  splitting: false,
});
