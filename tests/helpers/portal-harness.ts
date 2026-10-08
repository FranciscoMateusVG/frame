/**
 * Builds the portal app over a PrintApi (memory fake by default) with a
 * controllable clock, a capturing logger and a cookie-jar client that talks
 * to `app.request` like a browser would (Origin, cookies, CSRF).
 */
import { randomBytes, randomUUID } from 'node:crypto';
import type { Hono } from 'hono';
import { LoginThrottleMemory } from '../../src/adapters/login-throttle.memory.js';
import type { PrintApi } from '../../src/adapters/print-api.js';
import { PrintApiMemory } from '../../src/adapters/print-api.memory.js';
import { SessionStoreMemory } from '../../src/adapters/session-store.memory.js';
import { DEFAULT_SESSION_POLICY, type SessionPolicy } from '../../src/domain/portal-session.js';
import { createPortalApp } from '../../src/http/portal-app.js';
import type { PortalEnv } from '../../src/http/portal-http.js';
import type { Logger } from '../../src/observability/logger.js';
import type { Observability } from '../../src/observability/observability.js';
import { noopTracer } from '../../src/observability/tracer.js';

export const PORTAL_ORIGIN = 'https://grafica.test';
export const PASSWORD = 'correct horse battery staple';

export interface LogLine {
  level: string;
  message: string;
  attrs: Record<string, unknown> | undefined;
}

export class CapturingLogger implements Logger {
  readonly lines: LogLine[] = [];
  info(message: string, attrs?: Record<string, unknown>) {
    this.lines.push({ level: 'info', message, attrs });
  }
  warn(message: string, attrs?: Record<string, unknown>) {
    this.lines.push({ level: 'warn', message, attrs });
  }
  error(message: string, attrs?: Record<string, unknown>) {
    this.lines.push({ level: 'error', message, attrs });
  }
  debug(message: string, attrs?: Record<string, unknown>) {
    this.lines.push({ level: 'debug', message, attrs });
  }
}

export interface Harness {
  app: Hono<PortalEnv>;
  api: PrintApiMemory;
  sessions: SessionStoreMemory;
  logger: CapturingLogger;
  clock: { now: Date };
  client(options?: { ip?: string }): PortalClient;
}

export function createHarness(
  options: {
    printApi?: PrintApi;
    policy?: SessionPolicy;
    observability?: Observability;
    trustedProxies?: string[];
  } = {},
): Harness {
  const clock = { now: new Date('2026-10-08T12:00:00.000Z') };
  const api = new PrintApiMemory({ clock: () => clock.now });
  const logger = new CapturingLogger();
  const observability = options.observability ?? { logger, tracer: noopTracer() };
  const obs = { ...observability, logger };
  const sessions = new SessionStoreMemory();
  const app = createPortalApp({
    print: { printApi: options.printApi ?? api, observability: obs },
    session: {
      sessions,
      throttle: new LoginThrottleMemory(),
      policy: options.policy ?? DEFAULT_SESSION_POLICY,
      clock: () => clock.now,
      randomToken: () => randomBytes(32).toString('base64url'),
      password: PASSWORD,
      observability: obs,
    },
    portalOrigin: PORTAL_ORIGIN,
    trustedProxies: options.trustedProxies ?? [],
    logger,
    requestId: randomUUID,
  });
  return {
    app,
    api,
    sessions,
    logger,
    clock,
    client: (o = {}) => new PortalClient(app, o.ip),
  };
}

export interface RequestOptions {
  headers?: Record<string, string>;
  body?: BodyInit;
  json?: unknown;
  /** Omit or override the Origin header (default: the portal origin on non-GET). */
  origin?: string | null;
}

/** A tiny browser: cookie jar + Origin + optional CSRF header. */
export class PortalClient {
  readonly cookies = new Map<string, string>();
  readonly setCookies: string[] = [];
  csrf: string | undefined;

  constructor(
    private readonly app: Hono<PortalEnv>,
    private readonly ip?: string,
  ) {}

  async request(method: string, path: string, opts: RequestOptions = {}): Promise<Response> {
    const headers = new Headers(opts.headers);
    const origin =
      opts.origin === undefined ? (method === 'GET' ? null : PORTAL_ORIGIN) : opts.origin;
    if (origin) headers.set('Origin', origin);
    if (this.cookies.size > 0) {
      headers.set('Cookie', [...this.cookies].map(([k, v]) => `${k}=${v}`).join('; '));
    }
    let body = opts.body;
    if (opts.json !== undefined) {
      headers.set('Content-Type', 'application/json');
      body = JSON.stringify(opts.json);
    }
    const env = this.ip ? { incoming: { socket: { remoteAddress: this.ip } } } : undefined;
    const res = await this.app.request(
      `http://grafica.test${path}`,
      { method, headers, ...(body !== undefined ? { body } : {}) },
      env,
    );
    for (const raw of res.headers.getSetCookie()) {
      this.setCookies.push(raw);
      const [pair = ''] = raw.split(';');
      const eq = pair.indexOf('=');
      const name = pair.slice(0, eq);
      const value = pair.slice(eq + 1);
      if (/Max-Age=0/i.test(raw) || value === '') this.cookies.delete(name);
      else this.cookies.set(name, value);
    }
    return res;
  }

  get(path: string, opts: RequestOptions = {}) {
    return this.request('GET', path, opts);
  }

  /** JSON command with CSRF header. */
  post(path: string, json: unknown, headers: Record<string, string> = {}) {
    return this.request('POST', path, {
      json,
      headers: { ...(this.csrf ? { 'X-CSRF-Token': this.csrf } : {}), ...headers },
    });
  }

  postForm(path: string, form: FormData | URLSearchParams, opts: RequestOptions = {}) {
    return this.request('POST', path, { ...opts, body: form });
  }

  /** GET /api/session then POST /api/session with the password. */
  async login(password = PASSWORD): Promise<Response> {
    const pre = await this.get('/api/session');
    this.csrf = ((await pre.json()) as { csrfToken: string }).csrfToken;
    const res = await this.post('/api/session', { password });
    if (res.status === 200) {
      this.csrf = ((await res.clone().json()) as { csrfToken: string }).csrfToken;
    }
    return res;
  }
}
