/**
 * Example: Expose `createCat` over an HTTP API using Hono.
 *
 * Hono is a minimal, edge-friendly web framework. This example demonstrates
 * how to wire a Frame use case into HTTP routes without bleeding HTTP
 * concerns into the use case itself — the route handler is a thin shell:
 *
 *   1. parse + validate the request body
 *   2. call the use case with deps + input
 *   3. translate domain errors into HTTP responses
 *
 * The use case (`createCat`) and the repository (`CatRepositoryPostgres`)
 * are unchanged from the SDK examples. Hono is purely a transport adapter.
 *
 * Fully self-contained — uses Testcontainers to spin up a Postgres instance,
 * boots Hono on an ephemeral port, issues a few self-requests to demonstrate
 * the flow, then tears everything down.
 *
 * Usage: pnpm tsx examples/create-cat.hono.ts
 */
import { randomUUID } from 'node:crypto';
import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import { CatRepositoryPostgres } from '../src/adapters/cat-repository.postgres.js';
import { CatAlreadyExistsError } from '../src/errors/cat-already-exists.error.js';
import { InvalidCatNameError } from '../src/errors/invalid-cat-name.error.js';
import { ConsoleLogger } from '../src/observability/console-logger.js';
import { noopTracer } from '../src/observability/tracer.js';
import { createCat } from '../src/use-cases/create-cat.js';
import { createTestDatabase } from '../tests/helpers/test-db.js';

console.log('🐱 Frame Example: Create a Cat (HTTP via Hono)');
console.log('==============================================');
console.log('');

const { db, teardown } = await createTestDatabase();

try {
  const catRepository = new CatRepositoryPostgres(db);
  const deps = {
    catRepository,
    clock: () => new Date(),
    observability: {
      logger: new ConsoleLogger(),
      tracer: noopTracer(),
    },
  };

  // --- Build the Hono app ---
  // Routes are thin adapters: parse → invoke use case → translate errors.
  const app = new Hono();

  app.post('/cats', async (c) => {
    const body = await c.req.json<{ name?: unknown }>();
    try {
      const cat = await createCat(deps, {
        id: randomUUID(),
        name: typeof body.name === 'string' ? body.name : '',
      });
      return c.json(cat, 201);
    } catch (err) {
      if (err instanceof CatAlreadyExistsError) {
        return c.json({ error: err.code, message: err.message }, 409);
      }
      if (err instanceof InvalidCatNameError) {
        return c.json({ error: err.code, message: err.message }, 400);
      }
      throw err;
    }
  });

  app.get('/cats/:id', async (c) => {
    const cat = await catRepository.findById(c.req.param('id'));
    if (!cat) {
      return c.json({ error: 'NOT_FOUND' }, 404);
    }
    return c.json(cat);
  });

  // --- Boot on an ephemeral port ---
  const server = serve({ fetch: app.fetch, port: 0 });
  const address = server.address();
  if (!address || typeof address === 'string') {
    throw new Error('Failed to bind Hono server to a port.');
  }
  const baseUrl = `http://127.0.0.1:${address.port}`;
  console.log(`✅ Hono server listening on ${baseUrl}`);
  console.log('');

  try {
    // --- Demonstrate the API ---
    const createRes = await fetch(`${baseUrl}/cats`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'Whiskers' }),
    });
    const created = (await createRes.json()) as { id: string; name: string };
    console.log(`✅ POST /cats → ${createRes.status}`, created);

    const fetchRes = await fetch(`${baseUrl}/cats/${created.id}`);
    console.log(`✅ GET /cats/${created.id} → ${fetchRes.status}`, await fetchRes.json());

    // Duplicate name → 409
    const dupRes = await fetch(`${baseUrl}/cats`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'Whiskers' }),
    });
    console.log(`✅ POST /cats (duplicate) → ${dupRes.status}`, await dupRes.json());

    // Invalid name → 400
    const badRes = await fetch(`${baseUrl}/cats`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name: '' }),
    });
    console.log(`✅ POST /cats (invalid) → ${badRes.status}`, await badRes.json());

    console.log('');
    console.log('🎉 Example completed successfully!');
  } finally {
    await new Promise<void>((resolve, reject) => {
      server.close((err) => (err ? reject(err) : resolve()));
    });
  }
} finally {
  await teardown();
}
