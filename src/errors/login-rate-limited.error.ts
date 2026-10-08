/** Too many failed logins from this client (or this instance). */
export class LoginRateLimitedError extends Error {
  public readonly code = 'RATE_LIMITED' as const;

  constructor(public readonly retryAfterSeconds: number) {
    super('Too many login attempts.');
    this.name = 'LoginRateLimitedError';
  }
}
