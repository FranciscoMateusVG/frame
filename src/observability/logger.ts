/**
 * Logger interface — Frame's logging port.
 *
 * Three implementations ship with Frame:
 * - {@link ConsoleLogger} — pretty stdout output for examples and local dev.
 * - {@link NoopLogger} — silent, for tests and contexts where logging is undesirable.
 * - {@link OtelLogger} — forwards to the OTel Logs API with automatic trace correlation.
 *
 * Consumers may implement their own Logger to integrate with existing logging stacks.
 * The `attrs` parameter carries structured context — keep values serializable.
 */
export interface Logger {
  info(message: string, attrs?: Record<string, unknown>): void;
  warn(message: string, attrs?: Record<string, unknown>): void;
  error(message: string, attrs?: Record<string, unknown>): void;
  debug(message: string, attrs?: Record<string, unknown>): void;
}
