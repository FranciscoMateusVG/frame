import { logs, type Logger as OtelLoggerApi, SeverityNumber } from '@opentelemetry/api-logs';
import type { Logger } from './logger.js';

/**
 * OtelLogger — forwards log records to the OTel Logs API.
 *
 * Automatically correlates with the active span's trace context. The OTel SDK
 * reads the active span from AsyncLocalStorage-backed context propagation —
 * no manual trace_id threading required. Every log record emitted inside an
 * active span automatically carries that span's trace_id and span_id.
 *
 * Requires an OTel LoggerProvider to be registered via the SDK. Without one,
 * log calls are silently dropped (no-op safe, same as traces without a TracerProvider).
 *
 * @example
 * ```ts
 * // Consumer sets up the SDK (Frame never does this):
 * import { LoggerProvider, SimpleLogRecordProcessor, ConsoleLogRecordExporter } from '@opentelemetry/sdk-logs';
 * const logProvider = new LoggerProvider();
 * logProvider.addLogRecordProcessor(new SimpleLogRecordProcessor(new ConsoleLogRecordExporter()));
 * logs.setGlobalLoggerProvider(logProvider);
 *
 * // Then use OtelLogger in Frame:
 * const logger = new OtelLogger();
 * logger.info('cat.created', { catId: '...' });
 * // Log record automatically includes trace_id from the active span.
 * ```
 */
export class OtelLogger implements Logger {
  private readonly otelLogger: OtelLoggerApi;

  constructor(name = 'frame') {
    this.otelLogger = logs.getLogger(name);
  }

  info(message: string, attrs?: Record<string, unknown>): void {
    this.emit(SeverityNumber.INFO, 'INFO', message, attrs);
  }

  warn(message: string, attrs?: Record<string, unknown>): void {
    this.emit(SeverityNumber.WARN, 'WARN', message, attrs);
  }

  error(message: string, attrs?: Record<string, unknown>): void {
    this.emit(SeverityNumber.ERROR, 'ERROR', message, attrs);
  }

  debug(message: string, attrs?: Record<string, unknown>): void {
    this.emit(SeverityNumber.DEBUG, 'DEBUG', message, attrs);
  }

  private emit(
    severityNumber: SeverityNumber,
    severityText: string,
    message: string,
    attrs?: Record<string, unknown>,
  ): void {
    // The OTel SDK automatically picks up the active span context from
    // AsyncLocalStorage. No need to pass context explicitly — logs emitted
    // inside a startActiveSpan callback are automatically correlated.
    this.otelLogger.emit({
      severityNumber,
      severityText,
      body: message,
      attributes: attrs as Record<string, string | number | boolean | undefined>,
    });
  }
}
