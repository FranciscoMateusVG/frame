/**
 * LoginThrottle — failed-login limiter (spec §5): N failures per client per
 * window plus a per-instance ceiling, in memory with a bounded key set.
 */
export interface LoginThrottle {
  /** Whether a login attempt from `clientKey` may proceed now. */
  check(clientKey: string, now: Date): Promise<ThrottleDecision>;
  /** Count one failed attempt for `clientKey` (and for the instance). */
  recordFailure(clientKey: string, now: Date): Promise<void>;
}

export type ThrottleDecision =
  | { readonly allowed: true }
  | { readonly allowed: false; readonly retryAfterSeconds: number };
