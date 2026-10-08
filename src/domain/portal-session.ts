/**
 * Portal session rules (spec print-portal §5).
 *
 * A session is an opaque server-side record keyed by a random id held in a
 * host-only cookie. Before login the browser holds a pre-session that only
 * binds a CSRF token; login rotates to a fresh id and a fresh CSRF token.
 * Authenticated sessions expire 8h after login (absolute) or 30 min after
 * the last request (idle), whichever comes first.
 */

export interface PortalSession {
  readonly id: string;
  readonly csrfToken: string;
  readonly authenticated: boolean;
  readonly createdAt: Date;
  readonly lastSeenAt: Date;
}

export interface SessionPolicy {
  readonly absoluteTtlMs: number;
  readonly idleTtlMs: number;
}

export const DEFAULT_SESSION_POLICY: SessionPolicy = {
  absoluteTtlMs: 8 * 60 * 60 * 1000,
  idleTtlMs: 30 * 60 * 1000,
};

/** The instant at which the session stops being valid. */
export function sessionExpiresAt(session: PortalSession, policy: SessionPolicy): Date {
  const absolute = session.createdAt.getTime() + policy.absoluteTtlMs;
  const idle = session.lastSeenAt.getTime() + policy.idleTtlMs;
  return new Date(Math.min(absolute, idle));
}

export function isSessionExpired(
  session: PortalSession,
  policy: SessionPolicy,
  now: Date,
): boolean {
  return now.getTime() >= sessionExpiresAt(session, policy).getTime();
}

/** Minimum length of the shared print-shop password (spec §5). */
export const MIN_PASSWORD_LENGTH = 16;
/** Upper bound on a submitted password; longer input is a format error. */
export const MAX_PASSWORD_LENGTH = 1024;
