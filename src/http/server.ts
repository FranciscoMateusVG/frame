/**
 * Production entrypoint of the print-shop portal — the composition root.
 *
 *   PRINT_PORTAL_PASSWORD, INCLUIR_PRINT_SERVICE_TOKEN,
 *   INCLUIR_PRINT_API_ORIGIN, PRINT_PORTAL_ORIGIN   (required)
 *   PORT, HOST, PRINT_PORTAL_TRUSTED_PROXIES        (optional)
 *
 * Missing/invalid configuration refuses to start (exit 1) without printing
 * any value. Sessions live in this process only: a restart logs everyone
 * out, by design (spec §5). No database, no object storage.
 */
import { randomBytes, randomUUID } from 'node:crypto';
import { serve } from '@hono/node-server';
import { LoginThrottleMemory } from '../adapters/login-throttle.memory.js';
import { PrintApiHttp } from '../adapters/print-api.http.js';
import { SessionStoreMemory } from '../adapters/session-store.memory.js';
import { isSessionExpired, type SessionPolicy } from '../domain/portal-session.js';
import { ConsoleLogger } from '../observability/console-logger.js';
import { trace } from '../observability/tracer.js';
import { createPortalApp } from './portal-app.js';
import { loadPortalConfig, PortalConfigError } from './portal-config.js';

function main(): void {
  let config: ReturnType<typeof loadPortalConfig>;
  try {
    config = loadPortalConfig(process.env);
  } catch (error) {
    if (error instanceof PortalConfigError) {
      console.error(`print-portal: refusing to start — ${error.problems.join('; ')}`);
      process.exit(1);
    }
    throw error;
  }

  const logger = new ConsoleLogger();
  const observability = { logger, tracer: trace.getTracer('frame') };
  const clock = () => new Date();
  const policy: SessionPolicy = {
    absoluteTtlMs: config.sessionAbsoluteTtlMs,
    idleTtlMs: config.sessionIdleTtlMs,
  };
  const sessions = new SessionStoreMemory();

  const app = createPortalApp({
    print: {
      printApi: new PrintApiHttp({ origin: config.apiOrigin, token: config.serviceToken }),
      observability,
    },
    session: {
      sessions,
      throttle: new LoginThrottleMemory(),
      policy,
      clock,
      randomToken: () => randomBytes(32).toString('base64url'),
      password: config.password,
      observability,
    },
    portalOrigin: config.portalOrigin,
    trustedProxies: config.trustedProxies,
    logger,
    requestId: randomUUID,
  });

  const sweeper = setInterval(() => {
    const now = clock();
    void sessions.sweep((s) => isSessionExpired(s, policy, now));
  }, 60_000);
  sweeper.unref();

  const server = serve({ fetch: app.fetch, port: config.port, hostname: config.host }, (info) => {
    logger.info('portal.started', { port: info.port });
  });

  const shutdown = () => {
    clearInterval(sweeper);
    server.close(() => process.exit(0));
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

main();
