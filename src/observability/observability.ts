import type { Tracer } from '@opentelemetry/api';
import type { Logger } from './logger.js';

/**
 * Observability — groups Logger and Tracer because they always travel together.
 *
 * Use cases accept this as a single dependency instead of separate logger and
 * tracer arguments, preventing deps interfaces from ballooning as Frame grows.
 *
 * Adapters do NOT receive Observability. They use `trace.getTracer('frame')`
 * at module level and rely on OTel's AsyncLocalStorage-backed context
 * propagation for automatic parent-child span nesting. See CLAUDE.md for
 * the full instrumentation rules.
 *
 * @example
 * ```ts
 * export interface CreateCatDeps {
 *   readonly catRepository: CatRepository;
 *   readonly clock: () => Date;
 *   readonly observability: Observability;
 * }
 * ```
 */
export interface Observability {
  readonly logger: Logger;
  readonly tracer: Tracer;
}
