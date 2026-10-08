import type { LoginThrottle, ThrottleDecision } from './login-throttle.js';

export interface LoginThrottleLimits {
  /** Failed attempts allowed per client within the window (spec: 5). */
  readonly perClient: number;
  /** Failed attempts allowed for the whole instance within the window (spec: 100). */
  readonly perInstance: number;
  /** Sliding window length in ms (spec: 15 min). */
  readonly windowMs: number;
  /** Maximum distinct clients tracked; oldest evicted first. */
  readonly maxClients: number;
}

export const DEFAULT_LOGIN_THROTTLE_LIMITS: LoginThrottleLimits = {
  perClient: 5,
  perInstance: 100,
  windowMs: 15 * 60 * 1000,
  maxClients: 10_000,
};

/**
 * Sliding-window failed-login limiter held in process memory.
 *
 * Once a client has `perClient` failures inside the window, EVERY further
 * attempt is refused until the oldest failure leaves the window — a correct
 * password included, so the limiter is not an oracle. The instance-wide
 * ceiling bounds distributed guessing. Not instrumented (sub-ms map work).
 */
export class LoginThrottleMemory implements LoginThrottle {
  private readonly clients = new Map<string, number[]>();
  private instance: number[] = [];

  constructor(private readonly limits: LoginThrottleLimits = DEFAULT_LOGIN_THROTTLE_LIMITS) {}

  async check(clientKey: string, now: Date): Promise<ThrottleDecision> {
    const t = now.getTime();
    this.instance = this.prune(this.instance, t);
    const client = this.prune(this.clients.get(clientKey) ?? [], t);
    if (client.length > 0) this.clients.set(clientKey, client);
    else this.clients.delete(clientKey);

    const blockedUntil = Math.max(
      this.blockedUntil(client, this.limits.perClient),
      this.blockedUntil(this.instance, this.limits.perInstance),
    );
    if (blockedUntil > t) {
      return {
        allowed: false,
        retryAfterSeconds: Math.max(1, Math.ceil((blockedUntil - t) / 1000)),
      };
    }
    return { allowed: true };
  }

  async recordFailure(clientKey: string, now: Date): Promise<void> {
    const t = now.getTime();
    const client = this.prune(this.clients.get(clientKey) ?? [], t);
    client.push(t);
    this.clients.delete(clientKey);
    while (this.clients.size >= this.limits.maxClients) {
      const oldest = this.clients.keys().next();
      if (oldest.done) break;
      this.clients.delete(oldest.value);
    }
    this.clients.set(clientKey, client);
    this.instance = this.prune(this.instance, t);
    this.instance.push(t);
  }

  private prune(failures: number[], t: number): number[] {
    const from = t - this.limits.windowMs;
    return failures.filter((at) => at > from);
  }

  /** When the window will again hold fewer than `limit` failures (0 if it already does). */
  private blockedUntil(failures: readonly number[], limit: number): number {
    if (failures.length < limit) return 0;
    const pivot = failures[failures.length - limit];
    return pivot === undefined ? 0 : pivot + this.limits.windowMs;
  }
}
