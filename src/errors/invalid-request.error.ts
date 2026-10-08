/** A request the portal refuses on shape alone (400 INVALID_REQUEST). Never echoes input. */
export class InvalidRequestError extends Error {
  public readonly code = 'INVALID_REQUEST' as const;

  constructor(public readonly reason: string) {
    super(`Invalid request: ${reason}`);
    this.name = 'InvalidRequestError';
  }
}
