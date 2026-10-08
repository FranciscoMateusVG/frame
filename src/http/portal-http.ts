/**
 * Shared transport helpers for the portal: cookie, Origin, client identity,
 * the JSON error envelope, error mapping and download responses.
 */
import { getConnInfo } from '@hono/node-server/conninfo';
import type { Context } from 'hono';
import { getCookie } from 'hono/cookie';
import type { Download } from '../adapters/print-api.js';
import { CsrfFailedError } from '../errors/csrf-failed.error.js';
import { InvalidCredentialsError } from '../errors/invalid-credentials.error.js';
import { InvalidRequestError } from '../errors/invalid-request.error.js';
import { LoginRateLimitedError } from '../errors/login-rate-limited.error.js';
import { UnauthenticatedError } from '../errors/unauthenticated.error.js';
import { UpstreamRejectedError } from '../errors/upstream-rejected.error.js';
import { UpstreamUnavailableError } from '../errors/upstream-unavailable.error.js';
import type { Logger } from '../observability/logger.js';
import type { PrintDeps } from '../use-cases/print-deps.js';
import type { LoginDeps } from '../use-cases/session-deps.js';

/**
 * Host-only cookies (spec §5): `__Host-` forces Secure, Path=/ and no Domain.
 * The pre-session (CSRF binding for the login form) and the authenticated
 * session use different cookies; login clears the former and sets the latter.
 */
export const SESSION_COOKIE = '__Host-print_session';
export const PRESESSION_COOKIE = '__Host-print_presession';

/** Upload cap for quote/NF documents (5 MiB) and the whole body (+512 KiB). */
export const DOCUMENT_MAX_BYTES = 5 * 1024 * 1024;
export const UPLOAD_BODY_MAX_BYTES = DOCUMENT_MAX_BYTES + 512 * 1024;

export interface PortalDeps {
  readonly print: PrintDeps;
  readonly session: LoginDeps;
  readonly portalOrigin: string;
  readonly trustedProxies: readonly string[];
  readonly logger: Logger;
  /** Request id generator. */
  readonly requestId: () => string;
}

export type PortalEnv = { Variables: { requestId: string } };
export type PortalContext = Context<PortalEnv>;

function cookieId(c: PortalContext, name: string): string | undefined {
  const value = getCookie(c, name);
  return value && /^[A-Za-z0-9_-]{16,128}$/.test(value) ? value : undefined;
}

export function sessionIdFrom(c: PortalContext): string | undefined {
  return cookieId(c, SESSION_COOKIE);
}

export function preSessionIdFrom(c: PortalContext): string | undefined {
  return cookieId(c, PRESESSION_COOKIE);
}

function setCookie(c: PortalContext, name: string, value: string, clear = false): void {
  c.header(
    'Set-Cookie',
    `${name}=${value}; Path=/; Secure; HttpOnly; SameSite=Lax${clear ? '; Max-Age=0' : ''}`,
    { append: true },
  );
}

/** After login: the authenticated session cookie replaces the pre-session one. */
export function setSessionCookie(c: PortalContext, id: string): void {
  setCookie(c, SESSION_COOKIE, id);
  setCookie(c, PRESESSION_COOKIE, '', true);
}

export function setPreSessionCookie(c: PortalContext, id: string): void {
  setCookie(c, PRESESSION_COOKIE, id);
}

export function clearSessionCookies(c: PortalContext): void {
  setCookie(c, SESSION_COOKIE, '', true);
  setCookie(c, PRESESSION_COOKIE, '', true);
}

/** Browser commands must carry exactly our Origin (missing Origin fails too). */
export function originAllowed(c: PortalContext, portalOrigin: string): boolean {
  return c.req.header('origin') === portalOrigin;
}

/**
 * Client identity for login throttling: the socket peer address. Only when
 * that peer is an explicitly trusted proxy is the right-most X-Forwarded-For
 * entry (the address that proxy saw) used instead.
 */
export function clientKey(c: PortalContext, trustedProxies: readonly string[]): string {
  let peer = 'unknown';
  try {
    peer = getConnInfo(c).remote.address ?? 'unknown';
  } catch {
    // not running behind @hono/node-server (e.g. app.request in tests)
  }
  if (trustedProxies.includes(peer)) {
    const forwarded = c.req.header('x-forwarded-for')?.split(',').pop()?.trim();
    if (forwarded && /^[0-9a-fA-F:.]{2,45}$/.test(forwarded)) return forwarded;
  }
  return peer;
}

/**
 * The JSON error envelope. Extra headers go in the constructor: under
 * @hono/node-server, headers set on a Response AFTER construction can be
 * lost on the wire (its lightweight Response caches the init headers), so
 * never mutate a Response's headers once built.
 */
export function jsonError(
  c: PortalContext,
  status: number,
  code: string,
  message: string,
  options: { requestId?: string | undefined; retryAfterSeconds?: number | null | undefined } = {},
): Response {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json; charset=UTF-8',
    'Cache-Control': 'no-store',
  };
  if (options.retryAfterSeconds !== undefined && options.retryAfterSeconds !== null) {
    headers['Retry-After'] = String(options.retryAfterSeconds);
  }
  return new Response(
    JSON.stringify({
      error: { code, message, requestId: options.requestId ?? c.get('requestId') },
    }),
    { status, headers },
  );
}

const UNAVAILABLE_MESSAGE =
  'Serviço indisponível no momento. Nada foi confirmado; consulte novamente antes de repetir.';

/** Map any portal/upstream error to the JSON envelope. Unknown errors → 500, logged by id only. */
export function errorToJson(c: PortalContext, error: unknown, logger: Logger): Response {
  if (error instanceof UnauthenticatedError) {
    return jsonError(c, 401, 'UNAUTHENTICATED', 'Sessão ausente ou expirada. Entre novamente.');
  }
  if (error instanceof CsrfFailedError) {
    return jsonError(c, 403, 'CSRF_FAILED', 'Falha na verificação de segurança da requisição.');
  }
  if (error instanceof InvalidRequestError) {
    return jsonError(c, 400, 'INVALID_REQUEST', 'Requisição inválida.');
  }
  if (error instanceof InvalidCredentialsError) {
    return jsonError(c, 401, 'INVALID_CREDENTIALS', 'Senha incorreta.');
  }
  if (error instanceof LoginRateLimitedError) {
    return jsonError(c, 429, 'RATE_LIMITED', 'Muitas tentativas. Tente novamente mais tarde.', {
      retryAfterSeconds: error.retryAfterSeconds,
    });
  }
  if (error instanceof UpstreamRejectedError) {
    return jsonError(c, error.status, error.code, error.upstreamMessage, {
      requestId: error.requestId ?? undefined,
      retryAfterSeconds: error.retryAfterSeconds,
    });
  }
  if (error instanceof UpstreamUnavailableError) {
    return jsonError(c, 503, 'UPSTREAM_UNAVAILABLE', UNAVAILABLE_MESSAGE);
  }
  logger.error('portal.unhandled_error', {
    requestId: c.get('requestId'),
    errorName: error instanceof Error ? error.name : typeof error,
  });
  return jsonError(c, 500, 'INTERNAL', 'Erro interno.');
}

/** RFC 6266 attachment header with an ASCII fallback; strips controls, quotes, separators. */
export function contentDisposition(filename: string): string {
  const cleaned =
    filename
      // biome-ignore lint/suspicious/noControlCharactersInRegex: stripping control chars is the point
      .replace(/[\u0000-\u001f\u007f"\\/]/g, '_')
      .trim()
      .slice(0, 200) || 'arquivo';
  const ascii = cleaned.replace(/[^\x20-\x7e]/g, '_').replace(/[;%]/g, '_');
  return `attachment; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(cleaned)}`;
}

/** Stream a download to the browser: attachment only, never rendered inline. */
export function downloadResponse(download: Download): Response {
  return new Response(download.body, {
    status: 200,
    headers: {
      'Content-Type': download.mime,
      'Content-Length': String(download.size),
      'Content-Disposition': contentDisposition(download.filename),
      'X-Content-Type-Options': 'nosniff',
      'Content-Security-Policy': "sandbox; default-src 'none'",
      'Cache-Control': 'private, no-store',
    },
  });
}

/** Header value relayed upstream (If-Match / Idempotency-Key), bounded and printable. */
export function relayHeader(c: PortalContext, name: string): string | undefined {
  const value = c.req.header(name);
  if (value === undefined) return undefined;
  if (!/^[\x20-\x7e]{1,200}$/.test(value)) throw new InvalidRequestError(`${name} header`);
  return value;
}

/**
 * Drop undefined values so optional properties can be passed under
 * `exactOptionalPropertyTypes` without a conditional spread per field.
 */
export function compact<T extends Record<string, unknown>>(
  object: T,
): { [K in keyof T]?: Exclude<T[K], undefined> } {
  return Object.fromEntries(Object.entries(object).filter(([, v]) => v !== undefined)) as {
    [K in keyof T]?: Exclude<T[K], undefined>;
  };
}
