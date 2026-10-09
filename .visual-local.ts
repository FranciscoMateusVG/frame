import { randomBytes, randomUUID } from 'node:crypto';
import { serve } from '@hono/node-server';
import { LoginThrottleMemory } from './src/adapters/login-throttle.memory.js';
import { PrintApiHttp } from './src/adapters/print-api.http.js';
import { SessionStoreMemory } from './src/adapters/session-store.memory.js';
import { DEFAULT_SESSION_POLICY } from './src/domain/portal-session.js';
import { createPortalApp } from './src/http/portal-app.js';
import { NoopLogger } from './src/observability/noop-logger.js';
import { noopTracer } from './src/observability/tracer.js';
import { startFakeUpstream } from './tests/helpers/fake-print-upstream.js';
import { V2_ASSETS, V2_FIXTURE } from './tests/helpers/print-v2-fixture.js';

const upstream = await startFakeUpstream();
upstream.api.seedBatch(structuredClone(V2_FIXTURE.rebatchedBatch.batch), V2_ASSETS);
const obs = { logger: new NoopLogger(), tracer: noopTracer() };
const port = 47811;
const app = createPortalApp({
  print: {
    printApi: new PrintApiHttp({ origin: upstream.origin, token: upstream.token }),
    observability: obs,
  },
  session: {
    sessions: new SessionStoreMemory(),
    throttle: new LoginThrottleMemory(),
    policy: DEFAULT_SESSION_POLICY,
    clock: () => new Date(),
    randomToken: () => randomBytes(32).toString('base64url'),
    password: 'visual-check-password',
    observability: obs,
  },
  portalOrigin: `http://localhost:${port}`,
  trustedProxies: [],
  logger: obs.logger,
  requestId: randomUUID,
});
serve({ fetch: app.fetch, port, hostname: '127.0.0.1' });
console.log('ready');
