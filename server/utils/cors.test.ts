import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  corsHeadersForRequest,
  resolveCorsOrigin
} from './cors.ts';

describe('CORS policy', () => {
  it('allows Flutter Web localhost preview origins with credentials', () => {
    const headers = corsHeadersForRequest({
      origin: 'http://localhost:5174',
      requestHeaders: 'authorization,content-type'
    });

    assert.equal(
      headers?.['Access-Control-Allow-Origin'],
      'http://localhost:5174'
    );
    assert.equal(
      headers?.['Access-Control-Allow-Credentials'],
      'true'
    );
    assert.equal(
      headers?.['Access-Control-Allow-Headers'],
      'authorization,content-type'
    );
    assert.match(
      headers?.['Access-Control-Allow-Methods'] ?? '',
      /\bOPTIONS\b/
    );
  });

  it('allows configured origins in addition to local preview origins', () => {
    assert.equal(
      resolveCorsOrigin('https://app.example.com', {
        allowedOrigins: ['https://app.example.com']
      }),
      'https://app.example.com'
    );
  });

  it('rejects unrelated origins by default', () => {
    assert.equal(resolveCorsOrigin('https://evil.example.com'), null);
  });
});
