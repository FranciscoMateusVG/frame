import {
  isSessionExpired,
  MAX_PASSWORD_LENGTH,
  type PortalSession,
  sessionExpiresAt,
} from '../domain/portal-session.js';
import { CsrfFailedError } from '../errors/csrf-failed.error.js';
import { InvalidCredentialsError } from '../errors/invalid-credentials.error.js';
import { InvalidRequestError } from '../errors/invalid-request.error.js';
import { LoginRateLimitedError } from '../errors/login-rate-limited.error.js';
import { constantTimeEquals } from './constant-time-equals.js';
import { inSpan } from './in-span.js';
import type { LoginDeps } from './session-deps.js';

export interface LogInInput {
  /** Id from the pre-session cookie. */
  readonly sessionId: string | undefined;
  /** CSRF token presented with the request (header or form field). */
  readonly csrfToken: string | undefined;
  /** Client identity for throttling (socket address, or trusted-proxy XFF). */
  readonly clientKey: string;
  /** The submitted password, or undefined when the body was malformed. */
  readonly password: string | undefined;
}

export interface LogInResult {
  readonly session: PortalSession;
  readonly expiresAt: Date;
}

/**
 * Exchange the shared password for an authenticated session.
 *
 * Order matters: CSRF (bound to the pre-session) → body shape → throttle →
 * password.
 * A throttled client is refused even with the right password, so the
 * limiter is no oracle. Success rotates the session id and the CSRF token
 * (no fixation: the pre-session id is never promoted).
 *
 * @throws {CsrfFailedError} no live pre-session or token mismatch
 * @throws {InvalidRequestError} malformed body (password missing / not a string / too long)
 * @throws {LoginRateLimitedError} too many recent failures
 * @throws {InvalidCredentialsError} wrong password (identical for every wrong password)
 */
export function logIn(deps: LoginDeps, input: LogInInput): Promise<LogInResult> {
  const { sessions, throttle, policy, clock, randomToken, observability } = deps;
  const { logger, tracer } = observability;
  return inSpan(tracer, 'logIn', {}, async () => {
    const now = clock();
    const pre = input.sessionId ? await sessions.get(input.sessionId) : undefined;
    if (
      !pre ||
      isSessionExpired(pre, policy, now) ||
      input.csrfToken === undefined ||
      !constantTimeEquals(pre.csrfToken, input.csrfToken)
    ) {
      throw new CsrfFailedError();
    }

    const password = input.password;
    if (password === undefined || password.length === 0 || password.length > MAX_PASSWORD_LENGTH) {
      throw new InvalidRequestError('password format');
    }

    const decision = await throttle.check(input.clientKey, now);
    if (!decision.allowed) {
      logger.warn('portal.login.rate_limited', { retryAfterSeconds: decision.retryAfterSeconds });
      throw new LoginRateLimitedError(decision.retryAfterSeconds);
    }

    if (!constantTimeEquals(password, deps.password)) {
      await throttle.recordFailure(input.clientKey, now);
      logger.warn('portal.login.failed', {});
      throw new InvalidCredentialsError();
    }

    await sessions.delete(pre.id);
    const session: PortalSession = {
      id: randomToken(),
      csrfToken: randomToken(),
      authenticated: true,
      createdAt: now,
      lastSeenAt: now,
    };
    await sessions.put(session);
    logger.info('portal.login.succeeded', {});
    return { session, expiresAt: sessionExpiresAt(session, policy) };
  });
}
