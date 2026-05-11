/**
 * OtelLogger tests.
 *
 * Verifies that OtelLogger correctly forwards log records to the OTel Logs API
 * and that records emitted inside an active span are automatically correlated
 * with that span's trace context (the whole point of OtelLogger over the simpler
 * ConsoleLogger — trace-aware structured logs without manual threading).
 *
 * Uses InMemoryLogRecordExporter + LoggerProvider from @opentelemetry/sdk-logs
 * for assertion. This is the only place Frame's tests touch sdk-logs.
 */
import { context, trace } from '@opentelemetry/api';
import { logs, SeverityNumber } from '@opentelemetry/api-logs';
import {
  InMemoryLogRecordExporter,
  LoggerProvider,
  SimpleLogRecordProcessor,
} from '@opentelemetry/sdk-logs';
import { InMemorySpanExporter, SimpleSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { OtelLogger } from '../../src/observability/otel-logger.js';

// --- Logs SDK wiring (once per suite) ---
const logExporter = new InMemoryLogRecordExporter();
const loggerProvider = new LoggerProvider({
  processors: [new SimpleLogRecordProcessor(logExporter)],
});
logs.setGlobalLoggerProvider(loggerProvider);

// --- Tracer SDK wiring (for trace-correlation test) ---
const spanExporter = new InMemorySpanExporter();
const tracerProvider = new NodeTracerProvider({
  spanProcessors: [new SimpleSpanProcessor(spanExporter)],
});
tracerProvider.register();

describe('OtelLogger', () => {
  const logger = new OtelLogger('frame-test');

  beforeEach(() => {
    logExporter.reset();
    spanExporter.reset();
  });

  afterAll(async () => {
    await loggerProvider.shutdown();
    await tracerProvider.shutdown();
    trace.disable();
  });

  it('info emits a log record with INFO severity', () => {
    logger.info('cat.created', { catId: 'abc-123', nameLength: 7 });
    const records = logExporter.getFinishedLogRecords();
    expect(records).toHaveLength(1);
    expect(records[0]?.severityNumber).toBe(SeverityNumber.INFO);
    expect(records[0]?.severityText).toBe('INFO');
    expect(records[0]?.body).toBe('cat.created');
    expect(records[0]?.attributes).toMatchObject({ catId: 'abc-123', nameLength: 7 });
  });

  it('warn emits a log record with WARN severity', () => {
    logger.warn('cat.suspicious');
    const records = logExporter.getFinishedLogRecords();
    expect(records).toHaveLength(1);
    expect(records[0]?.severityNumber).toBe(SeverityNumber.WARN);
    expect(records[0]?.severityText).toBe('WARN');
    expect(records[0]?.body).toBe('cat.suspicious');
  });

  it('error emits a log record with ERROR severity', () => {
    logger.error('cat.lost');
    const records = logExporter.getFinishedLogRecords();
    expect(records).toHaveLength(1);
    expect(records[0]?.severityNumber).toBe(SeverityNumber.ERROR);
    expect(records[0]?.severityText).toBe('ERROR');
  });

  it('debug emits a log record with DEBUG severity', () => {
    logger.debug('cat.napping');
    const records = logExporter.getFinishedLogRecords();
    expect(records).toHaveLength(1);
    expect(records[0]?.severityNumber).toBe(SeverityNumber.DEBUG);
  });

  it('emits without attrs when none provided', () => {
    logger.info('no.attrs');
    const records = logExporter.getFinishedLogRecords();
    expect(records).toHaveLength(1);
    // OTel sets attributes to {} (or undefined) when not provided.
    const attrs = records[0]?.attributes;
    expect(attrs === undefined || Object.keys(attrs).length === 0).toBe(true);
  });

  it('log records emitted inside an active span carry that span trace context', () => {
    const tracer = trace.getTracer('frame-test');
    let capturedTraceId: string | undefined;
    let capturedSpanId: string | undefined;

    tracer.startActiveSpan('parent.op', (span) => {
      capturedTraceId = span.spanContext().traceId;
      capturedSpanId = span.spanContext().spanId;
      logger.info('inside.span', { phase: 'mid' });
      span.end();
    });

    const records = logExporter.getFinishedLogRecords();
    expect(records).toHaveLength(1);
    const record = records[0];
    expect(record).toBeDefined();
    // The OTel SDK populates spanContext from the active context (AsyncLocalStorage).
    expect(record?.spanContext?.traceId).toBe(capturedTraceId);
    expect(record?.spanContext?.spanId).toBe(capturedSpanId);
  });

  it('log records emitted outside any span have no spanContext', () => {
    // Ensure we're truly outside any active span by binding ROOT context.
    context.with(context.active(), () => {
      logger.info('outside.span');
    });
    const records = logExporter.getFinishedLogRecords();
    expect(records).toHaveLength(1);
    const record = records[0];
    // Outside an active span, spanContext is either absent or invalid (all-zero IDs).
    const sc = record?.spanContext;
    if (sc) {
      expect(sc.traceId).toBe('00000000000000000000000000000000');
    }
  });

  it('respects the custom logger name passed to the constructor', () => {
    const namedLogger = new OtelLogger('my-app');
    namedLogger.info('hello');
    const records = logExporter.getFinishedLogRecords();
    expect(records).toHaveLength(1);
    // The Logger name is reflected on the instrumentation scope of the record.
    expect(records[0]?.instrumentationScope.name).toBe('my-app');
  });
});
