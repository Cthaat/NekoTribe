// Synthetic public test keys only. Does not load application configuration.
import { mkdirSync, writeFileSync } from 'node:fs';
import jwt from 'jsonwebtoken';

const now = 1700000000;
const keys = {
  access: 'public-fixture-access-key-never-use-in-production-2026',
  refresh: 'public-fixture-refresh-key-never-use-in-production-2026'
};
const claims = { userId: 42, userName: '测试用户', sessionId: 'fixture-session-42', type: 'access',
  iat: now - 60, exp: now + 900, jti: 'fixture-access-jti-42' };
const sign = (payload = claims, algorithm = 'HS256', secret = keys.access) =>
  jwt.sign(Object.fromEntries(Object.entries(payload).filter(([, value]) => value !== undefined)), secret, { algorithm });
const valid = sign();
const cases = [];
function add(id, token, expectedValid, type = 'access') {
  cases.push({ id, type, token, expectedValid, ...(expectedValid ? { expectedUserId: 42 } : {}) });
}
add('access-hs256', valid, true);
add('access-hs384', sign(claims, 'HS384'), true);
add('access-hs512', sign(claims, 'HS512'), true);
add('refresh-hs256', sign({ ...claims, type: 'refresh', jti: 'fixture-refresh-jti-42' }, 'HS256', keys.refresh), true, 'refresh');
add('wrong-key', sign(claims, 'HS256', 'other-public-fixture-key'), false);
add('tampered-signature', `${valid.slice(0, -3)}xxx`, false);
add('expired', sign({ ...claims, exp: now - 1 }), false);
add('expires-at-now', sign({ ...claims, exp: now }), false);
add('expires-fraction-after-now', sign({ ...claims, exp: now + 0.5 }), true);
add('not-before-future', sign({ ...claims, nbf: now + 1 }), false);
add('not-before-fraction-future', sign({ ...claims, nbf: now + 0.5 }), false);
add('not-before-now', sign({ ...claims, nbf: now }), true);
add('wrong-token-type', sign({ ...claims, type: 'refresh' }), false);
add('missing-session', sign({ ...claims, sessionId: undefined }), false);
add('missing-jti', sign({ ...claims, jti: undefined }), false);
add('zero-user-id', sign({ ...claims, userId: 0 }), false);
add('fractional-user-id', sign({ ...claims, userId: 42.5 }), false);
add('unsafe-user-id', sign({ ...claims, userId: Number.MAX_SAFE_INTEGER + 1 }), false);
add('numeric-string-user-id', sign({ ...claims, userId: '42' }), true);
add('padded-numeric-string-user-id', sign({ ...claims, userId: ' 42 ' }), true);
add('missing-expiration', sign({ ...claims, exp: undefined }), true);
add('future-issued-at', sign({ ...claims, iat: now + 60, exp: now + 900 }), true);
add('algorithm-none', jwt.sign(claims, null, { algorithm: 'none' }), false);
add('malformed-token', 'not.a.jwt', false);
add('empty-token', '', false);

const output = { id: 'AUTH-TOKEN-CODEC', revision: 2, scope: 'unit-vectors-not-session-or-business-acceptance',
  generatedWith: 'Nuxt jsonwebtoken 9.0.2; signing follows v2SignAccessToken/v2SignRefreshToken', now, keys, cases,
  notes: [
    'Only public synthetic keys and identities. No application env, DB, Redis or real credentials.',
    'Signed token format and HMAC allowlist follow current Nuxt; explicit expected token kind is required by native codec.',
    'Missing exp and future iat reflect current JWT library behavior; database session expiration/revocation is still mandatory.',
    'Wrong token kind rejection is the desired typed codec boundary, not proof that the existing Nuxt refresh service checks type strictly.',
    'This does not settle AUTH-901..907 or prove complete authentication, cookies, login, refresh rotation or native endpoints.'
  ] };
mkdirSync(new URL('../specifications/scenarios/', import.meta.url), { recursive: true });
writeFileSync(new URL('../specifications/scenarios/auth-tokens.json', import.meta.url), JSON.stringify(output, null, 2) + '\n');
console.log(JSON.stringify({ cases: cases.length, scope: output.scope }));
