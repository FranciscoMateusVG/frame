import { type Span, SpanStatusCode } from '@opentelemetry/api';

/**
 * Mark a span as failed WITHOUT exporting the error's message or stack.
 *
 * `span.recordException(error)` and a status message copied from
 * `error.message` put whatever the error carries — upstream text, user
 * input, a crash detail — into exported telemetry. Portal spans record only
 * a sanitized error type (`error.type`: a contract code such as NOT_FOUND,
 * or the error class name) and a fixed status message (spec §5).
 */
export function markSpanFailed(span: Span, error: unknown): void {
  const type = errorType(error);
  span.setAttribute('error.type', type);
  span.setStatus({ code: SpanStatusCode.ERROR, message: type });
}

/** `code` when it is an upper-snake contract code, else the class name, else "Error". */
export function errorType(error: unknown): string {
  if (error instanceof Error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === 'string' && /^[A-Z][A-Z0-9_]{0,63}$/.test(code)) return code;
    if (/^[A-Za-z][A-Za-z0-9]{0,63}$/.test(error.name)) return error.name;
  }
  return 'Error';
}
