/** Wrong portal password. Same error for every wrong password. */
export class InvalidCredentialsError extends Error {
  public readonly code = 'INVALID_CREDENTIALS' as const;

  constructor() {
    super('Invalid credentials.');
    this.name = 'InvalidCredentialsError';
  }
}
