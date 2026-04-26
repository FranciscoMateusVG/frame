/** @type {import('dependency-cruiser').IConfiguration} */
module.exports = {
  forbidden: [
    {
      name: 'domain-no-external-imports',
      comment: 'Domain layer must not import from any other layer.',
      severity: 'error',
      from: { path: '^src/domain/' },
      to: {
        pathNot: '^src/domain/',
        // Allow external (node_modules) imports like zod
        path: '^src/',
      },
    },
    {
      name: 'use-cases-no-concrete-adapters',
      comment:
        'Use cases may import from domain/ and adapter interfaces, but never from concrete adapter implementations.',
      severity: 'error',
      from: { path: '^src/use-cases/' },
      to: {
        path: '^src/adapters/.*\\.(postgres|memory|sqlite)',
      },
    },
    {
      name: 'no-internal-index-imports',
      comment: 'Nothing internal should import from src/index.ts.',
      severity: 'error',
      from: { path: '^src/', pathNot: '^src/index\\.ts$' },
      to: { path: '^src/index\\.ts$' },
    },
    {
      name: 'no-circular',
      comment: 'No circular dependencies anywhere.',
      severity: 'error',
      from: { path: '^src/' },
      to: { circular: true },
    },
  ],
  options: {
    doNotFollow: {
      path: 'node_modules',
    },
    tsPreCompilationDeps: true,
    tsConfig: {
      fileName: 'tsconfig.json',
    },
    enhancedResolveOptions: {
      exportsFields: ['exports'],
      conditionNames: ['import', 'require', 'node', 'default'],
    },
  },
};
