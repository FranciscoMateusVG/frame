/**
 * Tracer re-exports from @opentelemetry/api.
 *
 * Frame re-exports the OTel types consumers need so they don't have to
 * depend on @opentelemetry/api directly. This also provides a `noopTracer`
 * convenience for contexts where tracing is not desired (e.g., simple examples).
 *
 * Production tracing requires an OTel SDK TracerProvider to be registered.
 * Without one, all tracer operations are no-ops (safe by design).
 */

import type { Span, Tracer } from '@opentelemetry/api';
import { SpanKind, SpanStatusCode, trace } from '@opentelemetry/api';

export type { Span, Tracer };
export { SpanKind, SpanStatusCode, trace };

/**
 * Returns a no-op Tracer instance.
 *
 * Useful for examples and tests that don't need tracing. Equivalent to
 * calling `trace.getTracer('noop')` without an SDK registered — all
 * span operations are silent no-ops.
 *
 * @example
 * ```ts
 * import { noopTracer } from 'frame';
 * const tracer = noopTracer();
 * // tracer.startActiveSpan('foo', ...) does nothing — zero overhead.
 * ```
 */
export function noopTracer(): Tracer {
  // Without a registered TracerProvider, getTracer returns a no-op tracer.
  // We use a distinctive name so it's identifiable in debugging.
  return trace.getTracer('frame-noop');
}
