import { isSessionExpired, type PortalSession } from '../domain/portal-session.js';
import { CsrfFailedError } from '../errors/csrf-failed.error.js';
import { UnauthenticatedError } from '../errors/unauthenticated.error.js';
import { constantTimeEquals } from './constant-time-equals.js';
import { inSpan } from './in-span.js';
import type { SessionDeps } from './session-deps.js';

export interface AuthenticateInput {
  readonly sessionId: string | undefined;
  /** When set, the request is a command and must carry the session's CSRF token. */
  readonly csrf?: { readonly token: string | undefined };
}

/**
 * Resolve the cookie to a live authenticated session and record activity
 * (idle timeout). Expired sessions are deleted on sight.
 *
 * @throws {UnauthenticatedError} no live authenticated session
 * @throws {CsrfFailedError} command without the matching CSRF token
 */
export function authenticateSession(
  deps: SessionDeps,
  input: AuthenticateInput,
): Promise<PortalSession> {
  const { sessions, policy, clock, observability } = deps;
  return inSpan(observability.tracer, 'authenticateSession', {}, async () => {
    const now = clock();
    const session = input.sessionId ? await sessions.get(input.sessionId) : undefined;
    if (!session) throw new UnauthenticatedError();
    if (isSessionExpired(session, policy, now)) {
      await sessions.delete(session.id);
      throw new UnauthenticatedError();
    }
    if (!session.authenticated) throw new UnauthenticatedError();
    if (
      input.csrf &&
      (input.csrf.token === undefined || !constantTimeEquals(session.csrfToken, input.csrf.token))
    ) {
      throw new CsrfFailedError();
    }
    await sessions.touch(session.id, now);
    return { ...session, lastSeenAt: now };
  });
}
