// @ts-check
//
// Frame folder-structure rules — enforced by eslint-plugin-project-structure.
//
// SCOPE: only the architectural directories — src/, tests/, examples/,
// migrations/, scripts/. Root config files and operational folders
// (.claude/, .husky/, .github/, docker/) are intentionally NOT modeled here;
// they're excluded by the `files` glob in eslint.config.mjs.
//
// WHAT THIS ENFORCES:
//   • src/ follows the hexagonal layout (domain / use-cases / adapters / errors
//     / observability / testing) with kebab-case filenames and the conventional
//     suffixes (.error.ts, .<impl>.ts).
//   • tests/ mirrors the unit/integration/helpers split with .test.ts suffix.
//   • examples/, migrations/, and scripts/ follow their respective conventions.
//
// WHAT THIS DOES NOT ENFORCE:
//   • Import-graph rules — those live in .dependency-cruiser.cjs.
//   • Lint or format — that's Biome.
//
// To allow a new file kind in an existing directory, add a node to its
// `children`. To allow a one-off exception, add it to `ignorePatterns` below.

import { createFolderStructure } from 'eslint-plugin-project-structure';

const KEBAB = '{kebab-case}';

export const folderStructureConfig = createFolderStructure({
  structure: [
    // ── src/ — the architecture proper ──
    {
      name: 'src',
      children: [
        { name: 'index.ts' },
        {
          name: 'domain',
          children: [{ name: `${KEBAB}.ts` }],
        },
        {
          name: 'use-cases',
          children: [{ name: `${KEBAB}.ts` }],
        },
        {
          name: 'adapters',
          children: [
            // <port>.ts (the interface) AND <port>.<impl>.ts (memory, postgres, ...)
            { name: `${KEBAB}.ts` },
            { name: `${KEBAB}.${KEBAB}.ts` },
          ],
        },
        {
          name: 'errors',
          children: [{ name: 'index.ts' }, { name: `${KEBAB}.error.ts` }],
        },
        {
          name: 'observability',
          children: [{ name: `${KEBAB}.ts` }],
        },
        {
          name: 'testing',
          children: [{ name: `${KEBAB}.ts` }],
        },
      ],
    },

    // ── tests/ — same shape as src/, plus shared helpers ──
    {
      name: 'tests',
      children: [
        {
          name: 'unit',
          children: [
            // Simple unit test AND adapter-flavored test (cat-repository.memory.test.ts).
            { name: `${KEBAB}.test.ts` },
            { name: `${KEBAB}.${KEBAB}.test.ts` },
          ],
        },
        {
          name: 'integration',
          children: [{ name: `${KEBAB}.test.ts` }, { name: `${KEBAB}.${KEBAB}.test.ts` }],
        },
        {
          name: 'helpers',
          children: [
            // Helpers may chain extra qualifiers (e.g. cat-repository.conformance.ts).
            { name: `${KEBAB}.ts` },
            { name: `${KEBAB}.${KEBAB}.ts` },
          ],
        },
      ],
    },

    // ── examples/ — one file per demo. ──
    // Conventions:
    //   • <use-case>.ts                          → bare SDK example (create-cat.ts)
    //   • <use-case>.with-<integration>.ts       → SDK example demonstrating a wiring
    //                                              (create-cat.with-otel.ts)
    //   • <use-case>.<flavor>.ts                 → transport / integration example
    //                                              (create-cat.hono.ts)
    {
      name: 'examples',
      children: [
        { name: `${KEBAB}.ts` },
        { name: `${KEBAB}.with-${KEBAB}.ts` },
        { name: `${KEBAB}.${KEBAB}.ts` },
      ],
    },

    // ── migrations/ — Kysely-style timestamped migrations ──
    //
    // Filenames are YYYYMMDD_NNN_<snake_name>.ts (e.g. 20260426_001_create_cats.ts).
    // The plugin only supports its `{reference}` macros (camelCase, snake_case,
    // kebab-case, etc.) — not arbitrary regex — so we use `{snake_case}.ts`,
    // which accepts the digits+underscores+letters shape these filenames have.
    // The timestamp/sequence convention is project policy, not lint-enforced here.
    {
      name: 'migrations',
      children: [{ name: '{snake_case}.ts' }],
    },

    // ── scripts/ — ad-hoc CLI helpers ──
    {
      name: 'scripts',
      children: [{ name: `${KEBAB}.ts` }, { name: `${KEBAB}.js` }],
    },
  ],
  ignorePatterns: ['**/*.generated.ts', '**/*.d.ts'],
});
