// Infrastructure lifecycle only. No batch states/fixtures are defined here.
import { randomUUID } from 'node:crypto';
import { createServer, type IncomingMessage } from 'node:http';

type Phase = 'idle' | 'prepared' | 'active' | 'finished' | 'aborted';
type Stamp = { boot_id: string; generation: number; trial_id: string };
type Seed<S> = { state: S; seed_sha256: string };
export type SeedFactory<S> = (scenario: string) => Seed<S>;

export class ControlError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
  }
}
function refuse(status: number, code: string): never {
  throw new ControlError(status, code);
}
const identifier = (s: unknown): s is string =>
  typeof s === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$/.test(s);

export class TrialControl<S> {
  readonly boot_id = randomUUID();
  private generation = 0;
  private phase: Phase = 'idle';
  private trial_id: string | null = null;
  private scenario: string | null = null;
  private seed_sha256: string | null = null;
  private state: S | undefined;
  private inFlight = 0;

  constructor(private readonly seed?: SeedFactory<S>) {}

  status() {
    return {
      boot_id: this.boot_id,
      generation: this.generation,
      phase: this.phase,
      trial_id: this.trial_id,
      scenario: this.scenario,
      seed_sha256: this.seed_sha256,
      configured: this.seed !== undefined,
      in_flight: this.inFlight,
    };
  }

  private fence(input: Stamp, requireTrial = true) {
    if (
      input.boot_id !== this.boot_id ||
      input.generation !== this.generation ||
      (requireTrial && input.trial_id !== this.trial_id)
    )
      refuse(409, 'STALE_CONTROL_FENCE');
  }

  reset(input: Stamp & { scenario: string }) {
    this.fence(input, false);
    if (!identifier(input.trial_id) || !identifier(input.scenario))
      refuse(400, 'INVALID_CONTROL_INPUT');
    if (this.phase === 'prepared' || this.phase === 'active' || this.inFlight)
      refuse(409, 'TRIAL_BUSY');
    const seed = this.seed;
    if (!seed) refuse(503, 'FREEZE_NOT_CONFIGURED');
    // Seed construction must finish before replacing the previous generation.
    const next = seed(input.scenario);
    if (!/^[a-f0-9]{64}$/.test(next.seed_sha256)) refuse(500, 'INVALID_SEED_DIGEST');
    this.state = next.state;
    this.generation += 1;
    this.trial_id = input.trial_id;
    this.scenario = input.scenario;
    this.seed_sha256 = next.seed_sha256;
    this.phase = 'prepared';
    return this.status();
  }

  start(input: Stamp) {
    this.fence(input);
    if (this.phase !== 'prepared') refuse(409, 'INVALID_CONTROL_PHASE');
    this.phase = 'active';
    return this.status();
  }

  end(input: Stamp, abort = false) {
    this.fence(input);
    if (this.inFlight) refuse(409, 'COMMAND_IN_FLIGHT');
    if (this.phase !== 'active' && !(abort && this.phase === 'prepared'))
      refuse(409, 'INVALID_CONTROL_PHASE');
    this.phase = abort ? 'aborted' : 'finished';
    return this.status();
  }

  current(): S {
    if (this.state === undefined) refuse(503, 'FREEZE_NOT_CONFIGURED');
    return this.state;
  }

  async command<T>(operation: (state: S) => Promise<T>): Promise<T> {
    if (this.phase !== 'active') refuse(409, 'TRIAL_NOT_ACTIVE');
    this.inFlight += 1;
    try {
      return await operation(this.current());
    } finally {
      this.inFlight -= 1;
    }
  }
}

async function body(req: IncomingMessage): Promise<Record<string, unknown>> {
  if (req.headers['content-type'] !== 'application/json') refuse(415, 'JSON_REQUIRED');
  if (Number(req.headers['content-length']) > 4096) refuse(413, 'CONTROL_BODY_TOO_LARGE');
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const part of req) {
    size += part.length;
    if (size > 4096) refuse(413, 'CONTROL_BODY_TOO_LARGE');
    chunks.push(part);
  }
  let value: unknown;
  try {
    value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    return refuse(400, 'INVALID_CONTROL_INPUT');
  }
  if (!value || typeof value !== 'object' || Array.isArray(value))
    refuse(400, 'INVALID_CONTROL_INPUT');
  return value as Record<string, unknown>;
}

function localOnly(req: IncomingMessage, host: string) {
  if (
    req.headers.host !== host ||
    req.headers.origin !== undefined ||
    req.headers['sec-fetch-site'] !== undefined
  )
    refuse(403, 'LOCAL_CONTROL_ONLY');
}

function stampInput(value: Record<string, unknown>, reset: boolean): Stamp {
  const allowed = reset
    ? ['boot_id', 'generation', 'trial_id', 'scenario']
    : ['boot_id', 'generation', 'trial_id'];
  if (
    Object.keys(value).length !== allowed.length ||
    Object.keys(value).some((k) => !allowed.includes(k)) ||
    typeof value.boot_id !== 'string' ||
    !Number.isSafeInteger(value.generation) ||
    Number(value.generation) < 0 ||
    !identifier(value.trial_id)
  )
    refuse(400, 'INVALID_CONTROL_INPUT');
  return value as Stamp;
}

async function dispatch<S>(req: IncomingMessage, control: TrialControl<S>) {
  if (req.method === 'GET' && req.url === '/status') return control.status();
  if (!['/reset', '/start', '/finish', '/abort'].includes(req.url ?? '')) refuse(404, 'NOT_FOUND');
  if (req.method !== 'POST') refuse(405, 'METHOD_NOT_ALLOWED');
  const value = await body(req);
  const stamp = stampInput(value, req.url === '/reset');
  if (req.url === '/reset') return control.reset({ ...stamp, scenario: value.scenario as string });
  if (req.url === '/start') return control.start(stamp);
  return control.end(stamp, req.url === '/abort');
}

/** Never attached to the service listener, published ports or proxy routes. */
export function startTrialAdmin<S>(control: TrialControl<S>, port = 4002) {
  const server = createServer(async (req, res) => {
    const respond = (status: number, value: unknown) => {
      res.writeHead(status, {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
        Connection: 'close',
      });
      res.end(JSON.stringify(value));
    };
    try {
      const bound = server.address();
      const host = typeof bound === 'object' && bound ? `127.0.0.1:${bound.port}` : '';
      localOnly(req, host);
      respond(200, await dispatch(req, control));
    } catch (error) {
      // Neither body, authorization, error message nor stack goes to logs/replies.
      respond(error instanceof ControlError ? error.status : 500, {
        error: { code: error instanceof ControlError ? error.code : 'CONTROL_INTERNAL' },
      });
    }
  });
  server.requestTimeout = 5000;
  server.headersTimeout = 5000;
  server.maxConnections = 8;
  server.listen(port, '127.0.0.1');
  return server;
}
