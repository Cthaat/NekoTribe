import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  configuredCorsAllowedOrigins,
  configuredCorsLocalhost,
  corsHeadersForRequest,
  mergeCorsVary,
  parseCorsAllowedOrigins,
  resolveCorsOrigin
} from './cors.ts';

test('localhost is disabled outside development unless explicitly opted in', () => {
  assert.equal(configuredCorsLocalhost({NODE_ENV: 'production'}), false);
  assert.equal(configuredCorsLocalhost({}), false);
  assert.equal(configuredCorsLocalhost({NODE_ENV: 'development'}), true);
  assert.equal(configuredCorsLocalhost({NODE_ENV: 'production', CORS_ALLOW_LOCALHOST_ORIGINS: 'true'}), true);
  assert.equal(configuredCorsLocalhost({NODE_ENV: 'development', NUXT_CORS_ALLOW_LOCALHOST_ORIGINS: 'false'}), false);
  for (const origin of ['http://localhost:5174', 'http://127.0.0.1:3000', 'http://[::1]:3000']) {
    assert.equal(resolveCorsOrigin(origin, {allowedOrigins: [], allowLocalhostOrigins: false}), null);
    assert.equal(resolveCorsOrigin(origin, {allowedOrigins: [], allowLocalhostOrigins: true}), origin);
  }
});

test('explicit origin configuration accepts only serialized HTTP(S) origins', () => {
  assert.deepEqual(parseCorsAllowedOrigins('https://app.example, https://app.example,*,null,file:///tmp,https://app.example/path'), ['https://app.example']);
  assert.deepEqual(configuredCorsAllowedOrigins({CORS_ALLOWED_ORIGINS: 'https://a.example', NUXT_CORS_ALLOWED_ORIGINS: 'https://b.example'}), ['https://a.example', 'https://b.example']);
  for (const origin of ['null', 'file:///tmp', 'https://app.example/path', 'https://app.example/', 'https://user:pass@app.example', 'https://app.example?x', 'https://app.example#x', ' https://app.example', 'https://app.example https://evil.example', 'http://localhost.evil.example']) {
    assert.equal(resolveCorsOrigin(origin, {allowedOrigins: ['https://app.example'], allowLocalhostOrigins: true}), null, origin);
  }
});

test('request headers and methods are allowlisted rather than reflected', () => {
  const base = {origin: 'https://app.example', allowedOrigins: ['https://app.example']};
  assert.equal(corsHeadersForRequest({...base, requestHeaders: 'Authorization, Content-Type,authorization'})?.['Access-Control-Allow-Headers'], 'authorization,content-type');
  for (const requestHeaders of ['x-admin', 'authorization\r\nx-admin:true', 'content-type,,authorization', '*', '']) {
    assert.equal(corsHeadersForRequest({...base, requestHeaders}), null);
  }
  assert.equal(corsHeadersForRequest({...base, requestMethod: 'TRACE'}), null);
  assert.equal(corsHeadersForRequest({...base, requestMethod: 'get'}), null);
});

test('Flutter request metadata passes exact-origin credentialed preflight', () => {
  const headers = corsHeadersForRequest({
    origin: 'http://localhost:30004', allowedOrigins: ['http://localhost:30004'], requestMethod: 'GET',
    requestHeaders: 'x-request-id,x-client-platform,x-device-fingerprint,x-device-info,accept'
  });
  assert.equal(headers?.['Access-Control-Allow-Origin'], 'http://localhost:30004');
  assert.equal(headers?.['Access-Control-Allow-Credentials'], 'true');
  assert.match(headers?.['Access-Control-Allow-Headers'] ?? '', /x-request-id/);
  assert.equal(corsHeadersForRequest({
    origin: 'https://unlisted.example', allowedOrigins: ['http://localhost:30004'], requestMethod: 'GET', requestHeaders: 'x-request-id'
  }), null);
});

test('Vary preserves existing values and wildcard and avoids duplicate Origin', () => {
  assert.equal(mergeCorsVary('*'), '*');
  const merged = mergeCorsVary(['Accept-Encoding', 'origin']);
  assert.match(merged, /Accept-Encoding/);
  assert.equal(merged.toLowerCase().split(',').map(value => value.trim()).filter(value => value === 'origin').length, 1);
  assert.match(merged, /Access-Control-Request-Headers/);
});
