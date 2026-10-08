import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: false,
    environment: 'node',
    include: ['tests/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'text-summary', 'json', 'html'],
      include: ['src/**/*.ts'],
      exclude: ['src/**/*.generated.ts', 'src/index.ts', 'src/testing/**'],
      thresholds: {
        'src/domain/cat.ts': {
          lines: 90,
          functions: 90,
          branches: 85,
        },
        'src/use-cases/create-cat.ts': {
          lines: 90,
          functions: 90,
          branches: 85,
        },
        // Print-shop portal: pure rules and use cases are held to the same bar
        // as the Cat template; the transport adapter and JSON API slightly lower
        // (defensive branches for malformed upstream answers).
        'src/domain/{money,monthly-close,portal-session,print-order}.ts': {
          lines: 90,
          functions: 90,
          branches: 85,
        },
        'src/use-cases/*.ts': {
          lines: 90,
          functions: 90,
          branches: 80,
        },
        'src/adapters/print-api.http.ts': {
          lines: 85,
          functions: 90,
          branches: 75,
        },
        'src/http/portal-api-routes.ts': {
          lines: 90,
          functions: 90,
          branches: 75,
        },
      },
    },
    testTimeout: 30000, // Testcontainers needs time to spin up
  },
});
