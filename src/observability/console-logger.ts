import type { Logger } from './logger.js';

type LogLevel = 'INFO' | 'WARN' | 'ERROR' | 'DEBUG';

/**
 * ConsoleLogger — pretty stdout output with timestamp, level, and structured attrs.
 *
 * Intended for examples and local development. Not suitable for production —
 * use {@link OtelLogger} with a proper OTel SDK setup instead.
 */
export class ConsoleLogger implements Logger {
  info(message: string, attrs?: Record<string, unknown>): void {
    this.log('INFO', message, attrs);
  }

  warn(message: string, attrs?: Record<string, unknown>): void {
    this.log('WARN', message, attrs);
  }

  error(message: string, attrs?: Record<string, unknown>): void {
    this.log('ERROR', message, attrs);
  }

  debug(message: string, attrs?: Record<string, unknown>): void {
    this.log('DEBUG', message, attrs);
  }

  private log(level: LogLevel, message: string, attrs?: Record<string, unknown>): void {
    const timestamp = new Date().toISOString();
    const attrsStr = attrs && Object.keys(attrs).length > 0 ? ` ${JSON.stringify(attrs)}` : '';
    const line = `[${timestamp}] ${level.padEnd(5)} ${message}${attrsStr}`;

    switch (level) {
      case 'ERROR':
        console.error(line);
        break;
      case 'WARN':
        console.warn(line);
        break;
      case 'DEBUG':
        console.debug(line);
        break;
      default:
        console.log(line);
    }
  }
}
