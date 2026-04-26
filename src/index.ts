// --- Domain ---

// --- Adapter Interfaces (public contract — implement your own) ---
export type { CatRepository } from './adapters/cat-repository.js';
export type { Database } from './adapters/database.js';
// --- Database utilities ---
export { createDatabase } from './adapters/database.js';
export type { Cat, CatId, CatName, CreateCatInput } from './domain/cat.js';
export { CatIdSchema, CatNameSchema, CreateCatInputSchema } from './domain/cat.js';

// --- Errors ---
export { CatAlreadyExistsError } from './errors/cat-already-exists.error.js';
export { InvalidCatNameError } from './errors/invalid-cat-name.error.js';
export { ConsoleLogger } from './observability/console-logger.js';
// --- Observability ---
export type { Logger } from './observability/logger.js';
export { NoopLogger } from './observability/noop-logger.js';
export type { Observability } from './observability/observability.js';
export { OtelLogger } from './observability/otel-logger.js';
export type { Span, Tracer } from './observability/tracer.js';
export { noopTracer, SpanKind, SpanStatusCode, trace } from './observability/tracer.js';
// --- Use Cases ---
export type { CreateCatDeps } from './use-cases/create-cat.js';
export { createCat } from './use-cases/create-cat.js';
