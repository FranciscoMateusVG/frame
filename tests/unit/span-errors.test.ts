import { describe, expect, it } from 'vitest';
import { UpstreamRejectedError } from '../../src/errors/upstream-rejected.error.js';
import { errorType } from '../../src/observability/span-errors.js';

describe('errorType', () => {
  it('uses contract codes, then class names, never messages', () => {
    expect(errorType(new UpstreamRejectedError(404, 'NOT_FOUND', 'secret text', 'r'))).toBe(
      'NOT_FOUND',
    );
    expect(errorType(new TypeError('MARKER secret'))).toBe('TypeError');
    expect(errorType(Object.assign(new Error('x'), { code: 'lower case MARKER' }))).toBe('Error');
    const odd = new Error('x');
    odd.name = 'MARKER with spaces';
    expect(errorType(odd)).toBe('Error');
    expect(errorType('a string MARKER')).toBe('Error');
    expect(errorType(undefined)).toBe('Error');
  });
});
