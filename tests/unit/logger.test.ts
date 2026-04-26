import { describe, expect, it, vi } from 'vitest';
import { ConsoleLogger } from '../../src/observability/console-logger.js';
import { NoopLogger } from '../../src/observability/noop-logger.js';

describe('ConsoleLogger', () => {
  const logger = new ConsoleLogger();

  it('info writes to console.log with formatted output', () => {
    const spy = vi.spyOn(console, 'log').mockImplementation(() => {});
    logger.info('test message', { key: 'value' });
    expect(spy).toHaveBeenCalledOnce();
    expect(spy.mock.calls[0]?.[0]).toMatch(/\[.*\] INFO {2}test message {"key":"value"}/);
    spy.mockRestore();
  });

  it('warn writes to console.warn', () => {
    const spy = vi.spyOn(console, 'warn').mockImplementation(() => {});
    logger.warn('warning');
    expect(spy).toHaveBeenCalledOnce();
    expect(spy.mock.calls[0]?.[0]).toMatch(/WARN/);
    spy.mockRestore();
  });

  it('error writes to console.error', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    logger.error('failure');
    expect(spy).toHaveBeenCalledOnce();
    expect(spy.mock.calls[0]?.[0]).toMatch(/ERROR/);
    spy.mockRestore();
  });

  it('debug writes to console.debug', () => {
    const spy = vi.spyOn(console, 'debug').mockImplementation(() => {});
    logger.debug('detail');
    expect(spy).toHaveBeenCalledOnce();
    expect(spy.mock.calls[0]?.[0]).toMatch(/DEBUG/);
    spy.mockRestore();
  });

  it('omits attrs when empty or undefined', () => {
    const spy = vi.spyOn(console, 'log').mockImplementation(() => {});
    logger.info('no attrs');
    expect(spy.mock.calls[0]?.[0]).not.toMatch(/\{/);
    spy.mockRestore();
  });
});

describe('NoopLogger', () => {
  const logger = new NoopLogger();

  it('all methods execute without throwing', () => {
    expect(() => logger.info('msg', { a: 1 })).not.toThrow();
    expect(() => logger.warn('msg')).not.toThrow();
    expect(() => logger.error('msg')).not.toThrow();
    expect(() => logger.debug('msg')).not.toThrow();
  });
});
