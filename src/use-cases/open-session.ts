import {
  isSessionExpired,
  type PortalSession,
  sessionExpiresAt,
} from '../domain/portal-session.js';
import { inSpan } from './in-span.js';
import type { SessionDeps } from './session-deps.js';

export interface OpenSessionResult {
  readonly session: PortalSession;
  /** True when a new pre-session was created (the cookie must be set). */
  readonly created: boolean;
  /** Expiry of an authenticated session; null for a pre-session. */
  readonly expiresAt: Date | null;
}

/**
 * Return the caller's first live session among `sessionIds` (session cookie
 * first, then pre-session cookie), or open an anonymous pre-session that
 * binds a CSRF token for the login form (GET /api/session, GET /login).
 */
export function openSession(
  deps: SessionDeps,
  input: { readonly sessionIds: readonly (string | undefined)[] },
): Promise<OpenSessionResult> {
  const { sessions, policy, clock, randomToken, observability } = deps;
  return inSpan(observability.tracer, 'openSession', {}, async (span) => {
    const now = clock();
    let existing: PortalSession | undefined;
    for (const id of input.sessionIds) {
      const candidate = id ? await sessions.get(id) : undefined;
      if (!candidate) continue;
      if (!isSessionExpired(candidate, policy, now)) {
        existing = candidate;
        break;
      }
      await sessions.delete(candidate.id);
    }
    if (existing) {
      await sessions.touch(existing.id, now);
      const touched = { ...existing, lastSeenAt: now };
      span.setAttribute('session.authenticated', touched.authenticated);
      return {
        session: touched,
        created: false,
        expiresAt: touched.authenticated ? sessionExpiresAt(touched, policy) : null,
      };
    }
    const session: PortalSession = {
      id: randomToken(),
      csrfToken: randomToken(),
      authenticated: false,
      createdAt: now,
      lastSeenAt: now,
    };
    await sessions.put(session);
    span.setAttribute('session.authenticated', false);
    return { session, created: true, expiresAt: null };
  });
}
