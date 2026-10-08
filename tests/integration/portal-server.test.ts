/**
 * The production entrypoint (src/http/server.ts) as a real process:
 * refuses to start without configuration, serves the journey against an
 * upstream over HTTP, and a restart invalidates every session (spec §5).
 */
import { type ChildProcess, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { request } from 'node:http';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { type FakeUpstream, startFakeUpstream } from '../helpers/fake-print-upstream.js';
import { seedTwoFileOrder } from '../helpers/print-fixtures.js';

const ROOT = fileURLToPath(new URL('../..', import.meta.url));
const TSX = `${ROOT}node_modules/.bin/tsx`;
const ORIGIN = 'https://grafica.test';
const PASSWORD = `pw-${randomUUID()}`;

interface Running {
  child: ChildProcess;
  base: string;
  output: () => string;
}

function start(env: Record<string, string>): Promise<Running> {
  const child = spawn(TSX, ['src/http/server.ts'], {
    cwd: ROOT,
    env: { PATH: process.env.PATH ?? '', ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  child.stdout?.on('data', (d) => {
    out += String(d);
  });
  child.stderr?.on('data', (d) => {
    out += String(d);
  });
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`portal did not start:\n${out}`)), 15_000);
    const check = () => {
      const port = /portal\.started \{"port":(\d+)\}/.exec(out)?.[1];
      if (port) {
        clearTimeout(timer);
        resolve({ child, base: `http://127.0.0.1:${port}`, output: () => out });
      }
    };
    child.stdout?.on('data', check);
    child.on('exit', (code) => {
      clearTimeout(timer);
      reject(Object.assign(new Error(`exited ${code}`), { code, output: out }));
    });
  });
}

/**
 * POST `totalBytes` of filler, 64 KiB at a time, with backpressure. Any
 * socket error before the response arrives rejects (the client could not
 * read the answer); errors after it are ignored.
 */
function sendOversized(
  base: string,
  path: string,
  headers: Record<string, string>,
  totalBytes: number,
  chunked: boolean,
  /** Keep writing the whole body even after the response (a naive client). */
  sendAll: boolean,
): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    let answered = false;
    const req = request(`${base}${path}`, {
      method: 'POST',
      headers: chunked ? headers : { ...headers, 'Content-Length': String(totalBytes) },
    });
    req.on('response', (res) => {
      answered = true;
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (d: string) => {
        body += d;
      });
      res.on('end', () => resolve({ status: res.statusCode ?? 0, body }));
      res.on('error', () => resolve({ status: res.statusCode ?? 0, body }));
    });
    req.on('error', (error) => {
      if (!answered) reject(error);
    });
    const chunk = Buffer.alloc(64 * 1024, 'x');
    let sent = 0;
    const pump = () => {
      while ((sendAll || !answered) && sent < totalBytes) {
        sent += chunk.length;
        if (!req.write(chunk)) {
          req.once('drain', pump);
          return;
        }
      }
      if (sendAll || !answered) req.end();
    };
    pump();
  });
}

function stop(running: Running): Promise<void> {
  return new Promise((resolve) => {
    if (running.child.exitCode !== null) return resolve();
    running.child.once('exit', () => resolve());
    running.child.kill('SIGTERM');
  });
}

/** Minimal cookie-aware fetch. */
function browser(base: string) {
  const jar = new Map<string, string>();
  return async (path: string, init: RequestInit & { csrf?: string } = {}) => {
    const headers = new Headers(init.headers);
    if (jar.size) headers.set('Cookie', [...jar].map(([k, v]) => `${k}=${v}`).join('; '));
    if (init.method && init.method !== 'GET') headers.set('Origin', ORIGIN);
    if (init.csrf) headers.set('X-CSRF-Token', init.csrf);
    const res = await fetch(`${base}${path}`, { ...init, headers, redirect: 'manual' });
    for (const raw of res.headers.getSetCookie()) {
      const [pair = ''] = raw.split(';');
      const [name = '', value = ''] = pair.split('=');
      if (value) jar.set(name, value);
      else jar.delete(name);
    }
    return res;
  };
}

describe('portal process (src/http/server.ts)', () => {
  let upstream: FakeUpstream;
  const env = () => ({
    PRINT_PORTAL_PASSWORD: PASSWORD,
    INCLUIR_PRINT_SERVICE_TOKEN: upstream.token,
    INCLUIR_PRINT_API_ORIGIN: upstream.origin,
    PRINT_PORTAL_ORIGIN: ORIGIN,
    PORT: '0',
    HOST: '127.0.0.1',
  });

  beforeAll(async () => {
    upstream = await startFakeUpstream();
  });
  afterAll(async () => {
    await upstream.close();
  });

  it('refuses to start without configuration, naming variables but no values', async () => {
    const { INCLUIR_PRINT_SERVICE_TOKEN: _omit, ...partial } = env();
    const failure = (await start(partial).catch((e) => e)) as { code: number; output: string };
    expect(failure.code).toBe(1);
    expect(failure.output).toContain('INCLUIR_PRINT_SERVICE_TOKEN is required');
    expect(failure.output).not.toContain(PASSWORD);
  }, 20_000);

  it('the login limiter 429 carries Retry-After through the real server', async () => {
    const running = await start(env());
    try {
      const go = browser(running.base);
      const { csrfToken } = (await (await go('/api/session')).json()) as { csrfToken: string };
      const attempt = () =>
        go('/api/session', {
          method: 'POST',
          csrf: csrfToken,
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ password: 'definitely-wrong-password' }),
        });
      for (let i = 0; i < 5; i++) expect((await attempt()).status).toBe(401);
      const limited = await attempt();
      expect(limited.status).toBe(429);
      expect(Number(limited.headers.get('retry-after'))).toBeGreaterThan(0);
    } finally {
      await stop(running);
    }
  }, 30_000);

  it('early 413/403 answers are readable by the client for bodies within the drain bound', async () => {
    const running = await start(env());
    try {
      const pre = await fetch(`${running.base}/api/session`);
      const { csrfToken } = (await pre.json()) as { csrfToken: string };
      const cookie = pre.headers
        .getSetCookie()
        .map((c) => c.split(';')[0])
        .join('; ');
      const headers = { Origin: ORIGIN, Cookie: cookie, 'X-CSRF-Token': csrfToken };
      const twoMiB = 2 * 1024 * 1024;

      for (const [path, type, chunked, expected] of [
        ['/api/session', 'application/json', false, 413],
        ['/api/session', 'application/json', true, 413],
        ['/login', 'application/x-www-form-urlencoded', false, 413],
        // A command refused before its body is parsed (no session): 401, body drained.
        [
          '/api/print/v1/monthly-closes/2026-09/invoice',
          'multipart/form-data; boundary=x',
          false,
          401,
        ],
      ] as const) {
        const res = await sendOversized(
          running.base,
          path,
          { ...headers, 'Content-Type': type },
          twoMiB,
          chunked,
          true,
        );
        expect(res.status, `${path} chunked=${chunked}`).toBe(expected);
        if (expected === 413 && path.startsWith('/api/')) {
          expect((JSON.parse(res.body) as { error: { code: string } }).error.code).toBe(
            'PAYLOAD_TOO_LARGE',
          );
        }
      }

      // Beyond the drain bound the server may cut the connection; it must not crash.
      const huge = await sendOversized(
        running.base,
        '/api/session',
        { ...headers, 'Content-Type': 'application/json' },
        12 * 1024 * 1024,
        true,
        false,
      ).catch(() => ({ status: -1, body: '' }));
      expect([413, -1]).toContain(huge.status);

      const ok = await fetch(`${running.base}/api/session`, {
        method: 'POST',
        headers: { ...headers, 'Content-Type': 'application/json' },
        body: JSON.stringify({ password: 'wrong-but-small-password' }),
      });
      expect(ok.status).toBe(401);
    } finally {
      await stop(running);
    }
  }, 30_000);

  it('relays an upstream 429 with its Retry-After through the real server', async () => {
    const running = await start(env());
    try {
      const go = browser(running.base);
      const pre = (await (await go('/api/session')).json()) as { csrfToken: string };
      const login = await go('/api/session', {
        method: 'POST',
        csrf: pre.csrfToken,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password: PASSWORD }),
      });
      expect(login.status).toBe(200);
      upstream.behaviour.rateLimitedFor = 42;
      const res = await go('/api/print/v1/orders');
      expect(res.status).toBe(429);
      expect(res.headers.get('retry-after')).toBe('42');
    } finally {
      upstream.behaviour.rateLimitedFor = 0;
      await stop(running);
    }
  }, 30_000);

  it('serves the journey over HTTP and a restart logs everyone out', async () => {
    const order = seedTwoFileOrder(upstream.api);
    let running = await start(env());
    try {
      const go = browser(running.base);
      expect((await go('/healthz')).status).toBe(200);
      const login = await go('/login');
      expect(login.status).toBe(200);
      const html = await login.text();
      expect(html).not.toContain(upstream.token);

      const pre = (await (await go('/api/session')).json()) as { csrfToken: string };
      const auth = await go('/api/session', {
        method: 'POST',
        csrf: pre.csrfToken,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password: PASSWORD }),
      });
      expect(auth.status).toBe(200);
      expect(auth.headers.getSetCookie().join('\n')).toMatch(
        /__Host-print_session=[A-Za-z0-9_-]{43}; Path=\/; Secure; HttpOnly; SameSite=Lax/,
      );

      const list = await go('/api/print/v1/orders');
      expect(list.status).toBe(200);
      const body = (await list.json()) as { items: { id: string }[] };
      expect(body.items.map((o) => o.id)).toContain(order.id);
      expect(JSON.stringify(body)).not.toContain(upstream.token);

      const page = await go(`/orders/${order.id}`);
      expect(page.status).toBe(200);
      expect(await page.text()).toContain('Arquivos retirados');

      await stop(running);
      running = await start(env());
      // New process, old cookie: the in-memory registry died with the old one.
      const goNew = browser(running.base);
      const replay = await fetch(`${running.base}/api/print/v1/orders`, {
        headers: {
          Cookie: auth.headers
            .getSetCookie()
            .map((c) => c.split(';')[0])
            .join('; '),
        },
      });
      expect(replay.status).toBe(401);
      expect((await goNew('/orders')).headers.get('location')).toBe('/login');
      expect(running.output()).not.toContain(PASSWORD);
      expect(running.output()).not.toContain(upstream.token);
    } finally {
      await stop(running);
    }
  }, 40_000);
});
