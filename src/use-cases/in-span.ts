import { type Span, SpanStatusCode, type Tracer } from '@opentelemetry/api';

/**
 * Run a use-case body inside exactly one span named after the use case.
 * Records the exception and sets ERROR status on failure, then rethrows —
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
      span.recordException(error as Error);
      span.setStatus({ code: SpanStatusCode.ERROR, message: (error as Error).message });
      throw error;
    } finally {
      span.end();
    }
  });
}
