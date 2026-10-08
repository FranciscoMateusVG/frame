/** Missing/foreign Origin, missing pre-session, or CSRF token mismatch. */
export class CsrfFailedError extends Error {
  public readonly code = 'CSRF_FAILED' as const;

  constructor() {
    super('CSRF validation failed.');
    this.name = 'CsrfFailedError';
  }
}
