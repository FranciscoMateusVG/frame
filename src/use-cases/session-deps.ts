import type { LoginThrottle } from '../adapters/login-throttle.js';
import type { SessionStore } from '../adapters/session-store.js';
import type { SessionPolicy } from '../domain/portal-session.js';
import type { Observability } from '../observability/observability.js';

/** Dependencies shared by the portal session use cases. */
export interface SessionDeps {
  readonly sessions: SessionStore;
  readonly policy: SessionPolicy;
  readonly clock: () => Date;
  /** Opaque random token, ≥ 256 bits (session ids and CSRF tokens). */
  readonly randomToken: () => string;
  readonly observability: Observability;
}

/** Dependencies of the login use case. */
export interface LoginDeps extends SessionDeps {
  readonly throttle: LoginThrottle;
  /** The shared print-shop password (PRINT_PORTAL_PASSWORD). */
  readonly password: string;
}
