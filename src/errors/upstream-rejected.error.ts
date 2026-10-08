/**
 * The Incluir service API answered with a contract error (4xx with
 * `{error:{code,message,requestId}}`). The portal relays code and status to
 * the browser; it never invents success and never retries a write.
 */
export class UpstreamRejectedError extends Error {
  public readonly code: string;

  constructor(
    public readonly status: number,
    code: string,
    public readonly upstreamMessage: string,
    public readonly requestId: string | null,
    public readonly retryAfterSeconds: number | null = null,
  ) {
    super(`Upstream rejected the request: ${status} ${code}`);
    this.name = 'UpstreamRejectedError';
    this.code = code;
  }
}
