/**
 * The service API could not be used: network failure, timeout, 5xx, a
 * redirect, a malformed response, or a bearer/config problem upstream.
 * Mapped to 503 UPSTREAM_UNAVAILABLE — never to "type your password again".
 */
export class UpstreamUnavailableError extends Error {
  public readonly code = 'UPSTREAM_UNAVAILABLE' as const;

  constructor(public readonly reason: string) {
    super(`Upstream unavailable: ${reason}`);
    this.name = 'UpstreamUnavailableError';
  }
}
