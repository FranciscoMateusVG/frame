import { type Span, SpanStatusCode, type Tracer } from '@opentelemetry/api';
import { markSpanFailed } from '../observability/span-errors.js';

/**
 * Run a use-case body inside exactly one span named after the use case.
 * Marks the span failed (error type only, never message/stack) and rethrows —
 * the same shape as createCat, factored out because the portal has a dozen
 * thin use cases. Attributes must be shapes/ids, never secrets or content.
 */
export function inSpan<T>(
  tracer: Tracer,
  name: string,
  attributes: Readonly<Record<string, string | number | boolean>>,
  fn: (span: Span) => Promise<T>,
): Promise<T> {
  return tracer.startActiveSpan(name, async (span) => {
    for (const [key, value] of Object.entries(attributes)) span.setAttribute(key, value);
    try {
      const result = await fn(span);
      span.setStatus({ code: SpanStatusCode.OK });
      return result;
    } catch (error) {
      markSpanFailed(span, error);
      throw error;
    } finally {
      span.end();
    }
  });
}
