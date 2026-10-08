import { describe, expect, it } from 'vitest';
import { loadPortalConfig, PortalConfigError } from '../../src/http/portal-config.js';

const valid = {
  PRINT_PORTAL_PASSWORD: 'a-long-shared-password',
  INCLUIR_PRINT_SERVICE_TOKEN: 'svc_0123456789abcdef0123456789abcdef',
  INCLUIR_PRINT_API_ORIGIN: 'https://api.incluir.test',
  PRINT_PORTAL_ORIGIN: 'https://grafica.incluir.test',
};

describe('loadPortalConfig', () => {
  it('parses a complete environment with defaults', () => {
    const config = loadPortalConfig(valid);
    expect(config).toMatchObject({
      apiOrigin: 'https://api.incluir.test',
      portalOrigin: 'https://grafica.incluir.test',
      port: 3000,
      trustedProxies: [],
      sessionAbsoluteTtlMs: 8 * 3600 * 1000,
      sessionIdleTtlMs: 30 * 60 * 1000,
    });
  });

  it('accepts test-only TTLs, port and trusted proxies', () => {
    const config = loadPortalConfig({
      ...valid,
      PORT: '4001',
      PRINT_PORTAL_TRUSTED_PROXIES: '10.0.0.1, 10.0.0.2',
      PRINT_PORTAL_SESSION_IDLE_SECONDS: '2',
      PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS: '5',
    });
    expect(config.port).toBe(4001);
    expect(config.trustedProxies).toEqual(['10.0.0.1', '10.0.0.2']);
    expect([config.sessionIdleTtlMs, config.sessionAbsoluteTtlMs]).toEqual([2000, 5000]);
    const max = loadPortalConfig({
      ...valid,
      PRINT_PORTAL_SESSION_IDLE_SECONDS: '1800',
      PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS: '28800',
    });
    expect([max.sessionIdleTtlMs, max.sessionAbsoluteTtlMs]).toEqual([1_800_000, 28_800_000]);
  });

  it.each([
    ['missing password', { PRINT_PORTAL_PASSWORD: undefined }],
    ['short password', { PRINT_PORTAL_PASSWORD: 'short' }],
    ['missing token', { INCLUIR_PRINT_SERVICE_TOKEN: undefined }],
    ['short token', { INCLUIR_PRINT_SERVICE_TOKEN: 'abc' }],
    ['api origin with path', { INCLUIR_PRINT_API_ORIGIN: 'https://api.incluir.test/api' }],
    ['api origin with credentials', { INCLUIR_PRINT_API_ORIGIN: 'https://u:p@api.incluir.test' }],
    ['portal origin not a URL', { PRINT_PORTAL_ORIGIN: 'grafica' }],
    ['ftp origin', { PRINT_PORTAL_ORIGIN: 'ftp://grafica.test' }],
    ['bad ttl', { PRINT_PORTAL_SESSION_IDLE_SECONDS: '0' }],
    ['idle ttl longer than 30 min', { PRINT_PORTAL_SESSION_IDLE_SECONDS: '1801' }],
    ['absolute ttl longer than 8 h', { PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS: '28801' }],
    ['password equals token', { PRINT_PORTAL_PASSWORD: valid.INCLUIR_PRINT_SERVICE_TOKEN }],
  ])('refuses %s, naming the variable but never its value', (_name, patch) => {
    const env = { ...valid, ...patch };
    let error: unknown;
    try {
      loadPortalConfig(env);
    } catch (e) {
      error = e;
    }
    expect(error).toBeInstanceOf(PortalConfigError);
    const message = (error as Error).message;
    for (const value of Object.values(patch)) {
      if (value && value.length > 3) expect(message).not.toContain(value);
    }
    expect(message).not.toContain(valid.INCLUIR_PRINT_SERVICE_TOKEN);
  });
});
