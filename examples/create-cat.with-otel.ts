/**
 * Example: Create a Cat with full OpenTelemetry tracing.
 *
 * This is the canonical documentation for how consumers wire up OTel with Frame.
 * It demonstrates the complete SDK setup that Frame deliberately does NOT do for you:
 * - TracerProvider with ConsoleSpanExporter
 * - Global provider registration
 * - createCat producing a parent span with nested db.cats.save child spans
 *
 * Spans are printed to stdout, proving the instrumentation works end-to-end.
 * In production, replace ConsoleSpanExporter with an OTLP exporter:
 *
 *   npm install @opentelemetry/exporter-trace-otlp-http
 *   import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
 *   const exporter = new OTLPTraceExporter({ url: 'http://localhost:4318/v1/traces' });
 *
 * For Honeycomb, Datadog, Grafana, etc. — consult their OTel integration docs.
 * Frame doesn't abstract exporter choice; you own your observability pipeline.
 *
 * Usage: pnpm tsx examples/create-cat.with-otel.ts
 */
import { randomUUID } from 'node:crypto';
import { trace } from '@opentelemetry/api';
import { ConsoleSpanExporter, SimpleSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';
import { CatRepositoryPostgres } from '../src/adapters/cat-repository.postgres.js';
import { ConsoleLogger } from '../src/observability/console-logger.js';
import { createCat } from '../src/use-cases/create-cat.js';
import { createTestDatabase } from '../tests/helpers/test-db.js';

// --- Step 1: Set up the OTel SDK (consumer's responsibility, not Frame's) ---

const provider = new NodeTracerProvider({
  spanProcessors: [new SimpleSpanProcessor(new ConsoleSpanExporter())],
});

// register() does two things:
// 1. Sets this as the global TracerProvider (trace.getTracer('frame') returns a real tracer)
// 2. Registers AsyncLocalStorageContextManager for automatic parent-child span nesting
// Note: trace.setGlobalTracerProvider() alone does NOT set up context propagation.
provider.register();

// Get a tracer for the use case layer
const tracer = trace.getTracer('frame-example');

console.log('🐱 Frame Example: Create a Cat (with OpenTelemetry)');
console.log('====================================================');
console.log('');
console.log('Spans will be printed to stdout by ConsoleSpanExporter.');
console.log('Look for: createCat (parent) → db.cats.save (child)');
console.log('');

// --- Step 2: Start the app (same as any Frame consumer) ---

const { db, teardown } = await createTestDatabase();

try {
  const catRepository = new CatRepositoryPostgres(db);
  const deps = {
    catRepository,
    clock: () => new Date(),
    observability: {
      logger: new ConsoleLogger(),
      tracer,
    },
  };

  // Create a cat — this produces a createCat span with a child db.cats.save span
  const cat = await createCat(deps, {
    id: randomUUID(),
    name: 'Whiskers',
  });
  console.log('');
  console.log('✅ Created cat:', cat);

  // Fetch it back — produces a db.cats.findById span
  const fetched = await catRepository.findById(cat.id);
  console.log('✅ Fetched cat:', fetched);

  // Delete it — produces a db.cats.deleteById span
  const deleted = await catRepository.deleteById(cat.id);
  console.log('✅ Deleted cat:', deleted);

  console.log('');
  console.log('🎉 Example completed successfully! Check the span output above.');
} finally {
  // Flush any remaining spans and shut down the provider
  await provider.shutdown();
  await teardown();
}
