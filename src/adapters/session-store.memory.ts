import type { PortalSession } from '../domain/portal-session.js';
import type { SessionStore } from './session-store.js';

export interface SessionStoreMemoryLimits {
  /** Maximum anonymous pre-sessions kept (oldest evicted first). */
  readonly maxPreSessions: number;
  /** Maximum authenticated sessions kept (oldest evicted first). */
  readonly maxSessions: number;
}

export const DEFAULT_SESSION_STORE_LIMITS: SessionStoreMemoryLimits = {
  maxPreSessions: 10_000,
  maxSessions: 1_000,
};

/**
 * In-memory session registry. Pre-sessions and authenticated sessions live
 * in separate maps with separate caps, so anonymous traffic can never push
 * a logged-in print shop out. Map insertion order gives oldest-first
 * eviction. Not instrumented: every operation is a sub-millisecond map
 * access (see CLAUDE.md "What NOT to Instrument").
 */
export class SessionStoreMemory implements SessionStore {
  private readonly pre = new Map<string, PortalSession>();
  private readonly auth = new Map<string, PortalSession>();

  constructor(private readonly limits: SessionStoreMemoryLimits = DEFAULT_SESSION_STORE_LIMITS) {}

  async put(session: PortalSession): Promise<void> {
    const [map, cap] = session.authenticated
      ? [this.auth, this.limits.maxSessions]
      : [this.pre, this.limits.maxPreSessions];
    map.delete(session.id);
    while (map.size >= cap) {
      const oldest = map.keys().next();
      if (oldest.done) break;
      map.delete(oldest.value);
    }
    map.set(session.id, session);
  }

  async get(id: string): Promise<PortalSession | undefined> {
    return this.auth.get(id) ?? this.pre.get(id);
  }

  async touch(id: string, at: Date): Promise<void> {
    const map = this.auth.has(id) ? this.auth : this.pre;
    const session = map.get(id);
    if (!session) return;
    // Re-insert so the most recently active session is the last evicted.
    map.delete(id);
    map.set(id, { ...session, lastSeenAt: at });
  }

  async delete(id: string): Promise<boolean> {
    return this.auth.delete(id) || this.pre.delete(id);
  }

  async sweep(isExpired: (session: PortalSession) => boolean): Promise<number> {
    let removed = 0;
    for (const map of [this.pre, this.auth]) {
      for (const [id, session] of map) {
        if (isExpired(session)) {
          map.delete(id);
          removed++;
        }
      }
    }
    return removed;
  }

  /** Number of stored sessions (pre + authenticated). For tests/metrics. */
  get size(): number {
    return this.pre.size + this.auth.size;
  }
}
