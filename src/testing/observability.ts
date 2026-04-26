/**
 * Test helper for consumers — provides an Observability instance backed by
 * an InMemorySpanExporter for asserting on emitted spans.
 *
 * Exported under the `frame/testing` subpath so it stays out of the
 * production bundle. Consumers writing use cases on top of Frame use this
 * to assert on span emission in their own tests.
 *
 * Uses NodeTracerProvider (not BasicTracerProvider) because it registers
 * the AsyncLocalStorageContextManager, which is required for parent-child
 * span nesting via startActiveSpan.
 *
 * This is the ONLY place Frame uses the OTel SDK. Production code only
 * sees the API, which is no-op safe by default. Document this boundary
 * clearly to consumers.
 *
 * @example
 * ```ts
 * import { createTestObservability } from 'frame/testing';
 *
 * const { observability, getSpans, reset, shutdown } = createTestObservability();
 *
 * afterAll(() => shutdown());
 * beforeEach(() => reset());
 *
 * it('emits a span', async () => {
 *   await myUseCase({ observability, ... }, input);
 *   const spans = getSpans();
 *   expect(spans).toHaveLength(1);
 *   expect(spans[0].name).toBe('myUseCase');
 * });
 * ```
 */
import { trace } from '@opentelemetry/api';
import type { ReadableSpan } from '@opentelemetry/sdk-trace-base';
import { InMemorySpanExporter, SimpleSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';
import { NoopLogger } from '../observability/noop-logger.js';
import type { Observability } from '../observability/observability.js';

export interface TestObservability {
  /** Observability instance to pass as a dependency. */
  observability: Observability;
  /** Returns all finished spans since the last reset. */
  getSpans(): ReadableSpan[];
  /** Clears all finished spans. Call in beforeEach for test isolation. */
  reset(): void;
  /** Shuts down the tracer provider. Call in afterAll. */
  shutdown(): Promise<void>;
}

export function createTestObservability(): TestObservability {
  const exporter = new InMemorySpanExporter();
  const provider = new NodeTracerProvider({
    spanProcessors: [new SimpleSpanProcessor(exporter)],
  });

  // register() does two things:
  // 1. Sets this as the global TracerProvider (so trace.getTracer('frame') in adapters works)
  // 2. Registers AsyncLocalStorageContextManager for automatic parent-child span nesting
  // Using trace.setGlobalTracerProvider() alone would NOT set up context propagation.
  provider.register();

  const tracer = provider.getTracer('frame-test');

  const observability: Observability = {
    logger: new NoopLogger(),
    tracer,
  };

  return {
    observability,
    getSpans: () => exporter.getFinishedSpans(),
    reset: () => exporter.reset(),
    shutdown: async () => {
      await provider.shutdown();
      trace.disable();
    },
  };
}
