import { createHash, timingSafeEqual } from 'node:crypto';

/**
 * Compare two secrets without leaking their length or common prefix through
 * timing: both sides are hashed to fixed-size digests first.
 */
export function constantTimeEquals(a: string, b: string): boolean {
  const da = createHash('sha256').update(a, 'utf8').digest();
  const db = createHash('sha256').update(b, 'utf8').digest();
  return timingSafeEqual(da, db);
}
