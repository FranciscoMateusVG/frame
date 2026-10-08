import { isSessionExpired } from '../domain/portal-session.js';
import { CsrfFailedError } from '../errors/csrf-failed.error.js';
import { constantTimeEquals } from './constant-time-equals.js';
import { inSpan } from './in-span.js';
import type { SessionDeps } from './session-deps.js';

/**
 * Revoke the caller's session immediately. Without a live session this is
 * a silent no-op (a repeated logout reveals nothing); with one, the CSRF
 * token must match.
 *
 * @throws {CsrfFailedError} live session but CSRF token mismatch
 */
export function logOut(
  deps: SessionDeps,
  input: { readonly sessionId: string | undefined; readonly csrfToken: string | undefined },
): Promise<void> {
  const { sessions, policy, clock, observability } = deps;
  return inSpan(observability.tracer, 'logOut', {}, async () => {
    const session = input.sessionId ? await sessions.get(input.sessionId) : undefined;
    if (!session || isSessionExpired(session, policy, clock())) {
      if (session) await sessions.delete(session.id);
      return;
    }
    if (input.csrfToken === undefined || !constantTimeEquals(session.csrfToken, input.csrfToken)) {
      throw new CsrfFailedError();
    }
    await sessions.delete(session.id);
    if (session.authenticated) observability.logger.info('portal.logout', {});
  });
}
