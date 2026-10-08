import { z } from 'zod';
import { MIN_PASSWORD_LENGTH } from '../domain/portal-session.js';

/**
 * Portal configuration (spec §5). Read once at startup from the environment;
 * anything missing or malformed refuses to start (fail closed, no literal
 * fallbacks). Error messages name the variable, never its value.
 */
export interface PortalConfig {
  /** Shared print-shop password (PRINT_PORTAL_PASSWORD, ≥ 16 chars). */
  readonly password: string;
  /** Service bearer for the Incluir API (INCLUIR_PRINT_SERVICE_TOKEN). */
  readonly serviceToken: string;
  /** Fixed Incluir API origin (INCLUIR_PRINT_API_ORIGIN). */
  readonly apiOrigin: string;
  /** Exact public origin of this portal (PRINT_PORTAL_ORIGIN); Origin header must match. */
  readonly portalOrigin: string;
  readonly port: number;
  readonly host: string;
  /** Socket addresses of reverse proxies whose X-Forwarded-For is trusted. */
  readonly trustedProxies: readonly string[];
  /** Session TTLs; overridable only for isolated test configurations. */
  readonly sessionAbsoluteTtlMs: number;
  readonly sessionIdleTtlMs: number;
}

const origin = (name: string) =>
  z
    .string({ error: `${name} is required` })
    .refine((value) => {
      try {
        const url = new URL(value);
        return (
          (url.protocol === 'https:' || url.protocol === 'http:') &&
          url.origin === value.replace(/\/$/, '') &&
          url.username === '' &&
          url.password === ''
        );
      } catch {
        return false;
      }
    }, `${name} must be a bare origin like https://host[:port]`)
    .transform((value) => new URL(value).origin);

const seconds = (name: string, fallback: number) =>
  z
    .string()
    .regex(/^[1-9][0-9]{0,6}$/, `${name} must be a positive integer (seconds)`)
    .transform((value) => Number(value) * 1000)
    .optional()
    .transform((value) => value ?? fallback * 1000);

const EnvSchema = z.object({
  PRINT_PORTAL_PASSWORD: z
    .string({ error: 'PRINT_PORTAL_PASSWORD is required' })
    .min(
      MIN_PASSWORD_LENGTH,
      `PRINT_PORTAL_PASSWORD must have at least ${MIN_PASSWORD_LENGTH} characters`,
    )
    .max(1024, 'PRINT_PORTAL_PASSWORD is too long'),
  INCLUIR_PRINT_SERVICE_TOKEN: z
    .string({ error: 'INCLUIR_PRINT_SERVICE_TOKEN is required' })
    .regex(
      /^[\x21-\x7e]{32,512}$/,
      'INCLUIR_PRINT_SERVICE_TOKEN must be 32–512 visible ASCII chars',
    ),
  INCLUIR_PRINT_API_ORIGIN: origin('INCLUIR_PRINT_API_ORIGIN'),
  PRINT_PORTAL_ORIGIN: origin('PRINT_PORTAL_ORIGIN'),
  PORT: z
    .string()
    .regex(/^[0-9]{1,5}$/, 'PORT must be a port number')
    .transform(Number)
    .optional()
    .transform((value) => value ?? 3000),
  HOST: z.string().min(1).optional(),
  PRINT_PORTAL_TRUSTED_PROXIES: z.string().optional(),
  PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS: seconds(
    'PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS',
    8 * 60 * 60,
  ),
  PRINT_PORTAL_SESSION_IDLE_SECONDS: seconds('PRINT_PORTAL_SESSION_IDLE_SECONDS', 30 * 60),
});

export class PortalConfigError extends Error {
  constructor(public readonly problems: readonly string[]) {
    super(`Invalid portal configuration: ${problems.join('; ')}`);
    this.name = 'PortalConfigError';
  }
}

/** Parse the environment. @throws {PortalConfigError} listing every problem (no values). */
export function loadPortalConfig(env: Readonly<Record<string, string | undefined>>): PortalConfig {
  const parsed = EnvSchema.safeParse(env);
  if (!parsed.success) {
    throw new PortalConfigError(parsed.error.issues.map((issue) => issue.message));
  }
  const e = parsed.data;
  if (e.PRINT_PORTAL_PASSWORD === e.INCLUIR_PRINT_SERVICE_TOKEN) {
    throw new PortalConfigError([
      'PRINT_PORTAL_PASSWORD and INCLUIR_PRINT_SERVICE_TOKEN must differ',
    ]);
  }
  return {
    password: e.PRINT_PORTAL_PASSWORD,
    serviceToken: e.INCLUIR_PRINT_SERVICE_TOKEN,
    apiOrigin: e.INCLUIR_PRINT_API_ORIGIN,
    portalOrigin: e.PRINT_PORTAL_ORIGIN,
    port: e.PORT,
    host: e.HOST ?? '0.0.0.0',
    trustedProxies: (e.PRINT_PORTAL_TRUSTED_PROXIES ?? '')
      .split(',')
      .map((s) => s.trim())
      .filter((s) => s.length > 0),
    sessionAbsoluteTtlMs: e.PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS,
    sessionIdleTtlMs: e.PRINT_PORTAL_SESSION_IDLE_SECONDS,
  };
}
