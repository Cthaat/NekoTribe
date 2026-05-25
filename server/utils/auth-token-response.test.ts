import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  buildV2TokenData,
  resolveV2RefreshToken
} from './auth-token-response.ts';

describe('auth token response contract', () => {
  it('includes token strings for Flutter clients that cannot read HttpOnly cookies', () => {
    const data = buildV2TokenData({
      sessionId: 'sess_test',
      accessToken: 'access.jwt',
      refreshToken: 'refresh.jwt',
      accessExpiresAt: new Date('2026-05-25T04:00:00.000Z'),
      refreshExpiresAt: new Date('2026-06-24T04:00:00.000Z')
    });

    assert.deepEqual(data, {
      session_id: 'sess_test',
      access_token: 'access.jwt',
      refresh_token: 'refresh.jwt',
      access_token_expires_at: '2026-05-25T04:00:00.000Z',
      refresh_token_expires_at: '2026-06-24T04:00:00.000Z'
    });
  });

  it('accepts refresh tokens from request body when cookies are unavailable', () => {
    assert.equal(
      resolveV2RefreshToken(null, { refresh_token: 'body.refresh.jwt' }),
      'body.refresh.jwt'
    );
    assert.equal(
      resolveV2RefreshToken('cookie.refresh.jwt', {
        refresh_token: 'body.refresh.jwt'
      }),
      'cookie.refresh.jwt'
    );
    assert.equal(resolveV2RefreshToken(null, {}), null);
  });
});
