import type { Logger } from './logger.js';

/**
 * NoopLogger — does nothing.
 *
 * Use in tests and any context where logging output is undesirable.
 * Zero overhead, zero side effects.
 */
export class NoopLogger implements Logger {
  info(_message: string, _attrs?: Record<string, unknown>): void {}
  warn(_message: string, _attrs?: Record<string, unknown>): void {}
  error(_message: string, _attrs?: Record<string, unknown>): void {}
  debug(_message: string, _attrs?: Record<string, unknown>): void {}
}
