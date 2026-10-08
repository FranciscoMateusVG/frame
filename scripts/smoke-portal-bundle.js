// Smoke test of the portal production artifact (dist-portal/server.mjs):
// copied alone into an empty temp dir (no node_modules), it must refuse to
// start without configuration and, configured, serve /healthz and /login.
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { copyFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const dir = mkdtempSync(join(tmpdir(), 'portal-bundle-'));
copyFileSync('dist-portal/server.mjs', join(dir, 'server.mjs'));

function run(env) {
  const child = spawn(process.execPath, ['server.mjs'], {
    cwd: dir,
    env: { PATH: process.env.PATH, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  child.stdout.on('data', (d) => (out += d));
  child.stderr.on('data', (d) => (out += d));
  return { child, out: () => out };
}

function fail(message) {
  console.error(`❌ ${message}`);
  rmSync(dir, { recursive: true, force: true });
  process.exit(1);
}

const bare = run({});
const code = await new Promise((resolve) => bare.child.on('exit', resolve));
if (code !== 1 || !bare.out().includes('refusing to start'))
  fail(`unconfigured bundle exited ${code}`);
console.log('✅ bundle refuses to start without configuration');

const password = randomBytes(18).toString('base64url');
const live = run({
  PRINT_PORTAL_PASSWORD: password,
  INCLUIR_PRINT_SERVICE_TOKEN: randomBytes(32).toString('base64url'),
  INCLUIR_PRINT_API_ORIGIN: 'http://127.0.0.1:9',
  PRINT_PORTAL_ORIGIN: 'https://grafica.test',
  PORT: '0',
  HOST: '127.0.0.1',
  BUILD_SHA: 'runtime-must-not-override-the-artifact',
});
let port;
for (let i = 0; i < 100 && !port; i++) {
  port = /portal\.started \{"port":(\d+)\}/.exec(live.out())?.[1];
  if (!port) await new Promise((r) => setTimeout(r, 50));
}
try {
  if (!port) fail(`bundle did not start:\n${live.out()}`);
  const revision = await fetch(`http://127.0.0.1:${port}/version`);
  if (
    revision.status !== 200 ||
    revision.headers.get('cache-control') !== 'no-store' ||
    !revision.headers.get('content-type')?.startsWith('application/json') ||
    JSON.stringify(await revision.json()) !==
      JSON.stringify({ revision: process.env.BUILD_SHA || 'unknown' })
  )
    fail('bundle did not preserve its build revision');
  console.log('✅ bundle revision is baked in, public, no-store, and immune to runtime BUILD_SHA');
  const health = await fetch(`http://127.0.0.1:${port}/healthz`);
  const login = await fetch(`http://127.0.0.1:${port}/login`);
  if (health.status !== 200 || login.status !== 200)
    fail(`healthz ${health.status}, login ${login.status}`);
  if (!(await login.text()).includes('Senha')) fail('login page without the password field');
  if (live.out().includes(password)) fail('bundle printed the password');
  console.log(`✅ bundle (no node_modules) serves /healthz and /login on :${port}`);
} finally {
  live.child.kill('SIGTERM');
  rmSync(dir, { recursive: true, force: true });
}
