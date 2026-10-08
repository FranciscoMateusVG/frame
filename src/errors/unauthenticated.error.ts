/** No valid authenticated portal session. */
export class UnauthenticatedError extends Error {
  public readonly code = 'UNAUTHENTICATED' as const;

  constructor() {
    super('Authentication required.');
    this.name = 'UnauthenticatedError';
  }
}
