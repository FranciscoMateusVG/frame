export class InvalidCatNameError extends Error {
  public readonly code = 'INVALID_CAT_NAME' as const;

  constructor(public readonly reason: string) {
    super(`Invalid cat name: ${reason}`);
    this.name = 'InvalidCatNameError';
  }
}
