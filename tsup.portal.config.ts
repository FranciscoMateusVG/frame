import { defineConfig } from 'tsup';

/**
 * Production artifact of the print-shop portal: ONE self-contained ESM file
 * (dependencies inlined), so the runtime needs only `node` — no
 * node_modules. Run: `node dist-portal/server.mjs` with the portal env.
 */
export default defineConfig({
  entry: { server: 'src/http/server.ts' },
  format: ['esm'],
  platform: 'node',
  target: 'node20',
  outDir: 'dist-portal',
  outExtension: () => ({ js: '.mjs' }),
  noExternal: [/.*/],
  dts: false,
  sourcemap: true,
  clean: true,
  splitting: false,
  // Inlined CommonJS deps may call require(); give the ESM bundle one.
  banner: {
    js: "import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);",
  },
});
