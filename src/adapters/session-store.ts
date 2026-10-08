import type { PortalSession } from '../domain/portal-session.js';

/**
 * SessionStore — the server-side session registry (spec §5).
 *
 * The only implementation is in memory: one replica, sessions die with the
 * process (a restart invalidates every session, by design). The store is
 * bounded so that a flood of anonymous pre-sessions cannot exhaust memory
 * or evict authenticated sessions.
 */
export interface SessionStore {
  /** Insert a session. May evict expired or, when full, the oldest entries of the same kind. */
  put(session: PortalSession): Promise<void>;
  get(id: string): Promise<PortalSession | undefined>;
  /** Record activity (idle timeout) on an existing session. No-op if absent. */
  touch(id: string, at: Date): Promise<void>;
  /** Remove a session. Returns true if it existed. */
  delete(id: string): Promise<boolean>;
  /** Remove every session for which `isExpired` holds. Returns how many were removed. */
  sweep(isExpired: (session: PortalSession) => boolean): Promise<number>;
}
