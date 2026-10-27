import { readFileSync, writeFileSync } from 'node:fs';
const tokens = JSON.parse(readFileSync(new URL('../specifications/scenarios/auth-tokens.json', import.meta.url)));
const token = tokens.cases.find(item => item.id === 'access-hs256').token;
const current = 'fixture-session-42';
const now = tokens.now;
const sessions = [
  { sessionId: current, userId: 42, accessJti: 'fixture-access-jti-42', accessExpiresAt: now + 900, revokedAt: null, lastAccessedAt: now - 60 },
  { sessionId: 'peer', userId: 42, accessJti: 'peer-jti', accessExpiresAt: now + 900, revokedAt: null, lastAccessedAt: now - 60 },
  { sessionId: 'expired', userId: 42, accessJti: 'expired-jti', accessExpiresAt: now - 1, revokedAt: null, lastAccessedAt: now - 60 },
  { sessionId: 'foreign', userId: 7, accessJti: 'foreign-jti', accessExpiresAt: now + 900, revokedAt: null, lastAccessedAt: now - 60 },
  { sessionId: 'revoked', userId: 42, accessJti: 'revoked-jti', accessExpiresAt: now + 900, revokedAt: now - 10, lastAccessedAt: now - 60 }
];
const prefix = '/api/v2/auth/sessions/';
const envelope = (code, message, data = null) => ({ code, message, data, meta: null });
const cases = [];
function add(id, target, change = () => {}) {
  const item = structuredClone({
    id, sessions,
    requests: [{ method: 'DELETE', path: prefix + target, headers: { authorization: `Bearer ${token}` },
      expectedStatus: 200, expectedEnvelope: envelope(200, 'session revoked'), expectedClearedCookies: [] }],
    expectedTouches: 1, expectedRevokes: 1,
    expectedRevokedSessionIds: ['revoked', target].sort(), expectedTouchedSessionIds: [current]
  });
  change(item); cases.push(item);
}
function deny(item, status = 401, message = 'Token无效或已过期', beforeTouch = false) {
  item.requests[0].expectedStatus = status;
  item.requests[0].expectedEnvelope = envelope(status === 401 ? 40101 : 40401, message);
  item.expectedRevokedSessionIds = ['revoked'];
  if (status === 401) { item.expectedRevokes = 0; item.expectedTouchedSessionIds = []; }
  if (beforeTouch) item.expectedTouches = 0;
}
add('SESSION-R001', 'peer');
add('SESSION-R002', 'foreign', x => deny(x, 404, '会话不存在'));
add('SESSION-R003', 'missing', x => deny(x, 404, '会话不存在'));
add('SESSION-R004', 'revoked', x => deny(x, 404, '会话不存在'));
add('SESSION-R005', 'expired');
add('SESSION-R006', current, x => {
  x.requests[0].expectedClearedCookies = ['access_token', 'refresh_token'];
  x.requests.push({ method: 'DELETE', path: prefix + 'peer', headers: { authorization: `Bearer ${token}` }, expectedStatus: 401,
    expectedEnvelope: envelope(40101, 'Token无效或已过期'), expectedClearedCookies: [] });
  x.expectedTouches = 2;
});
add('SESSION-R007', 'others', x => {
  x.requests[0].expectedEnvelope = envelope(200, 'other sessions revoked', { revoked_count: 2 });
  x.expectedRevokedSessionIds = ['expired', 'peer', 'revoked'];
});
add('SESSION-R008', 'others', x => {
  x.sessions = x.sessions.filter(row => !['peer', 'expired'].includes(row.sessionId));
  x.requests[0].expectedEnvelope = envelope(200, 'other sessions revoked', { revoked_count: 0 });
  x.expectedRevokedSessionIds = ['revoked'];
});
add('SESSION-R009', 'peer', x => { x.requests[0].headers = {}; deny(x, 401, '请先登录', true); });
add('SESSION-R010', 'peer', x => { x.requests[0].headers.authorization = 'Bearer bad-fixture-token'; deny(x, 401, undefined, true); });
add('SESSION-R011', 'peer', x => { x.sessions[0].revokedAt = now - 1; deny(x); x.expectedRevokedSessionIds = [current, 'revoked'].sort(); });
add('SESSION-R012', 'peer', x => { x.sessions[0].accessJti = 'rotated-jti'; deny(x); });
add('SESSION-R013', 'peer', x => { x.sessions[0].userId = 7; deny(x); });
add('SESSION-R014', 'peer', x => { x.sessions[0].accessExpiresAt = now; deny(x); });
add('SESSION-R015', 'peer', x => { x.sessions = x.sessions.slice(1); deny(x); });
add('SESSION-R016', 'peer', x => { x.requests[0].headers.cookie = 'access_token=bad-fixture-token'; deny(x, 401, undefined, true); });
add('SESSION-R017', 'peer', x => { x.requests[0].headers.cookie = 'access_token='; });
add('SESSION-R018', 'peer', x => { x.requests[0].headers.authorization = token; });
add('SESSION-R019', 'peer', x => { x.requests[0].headers = { cookie: `access_token=${token.replaceAll('.', '%2E')}` }; });
add('SESSION-R020', '%70eer', x => deny(x, 404, '会话不存在'));
add('SESSION-R021', '%6fthers', x => deny(x, 404, '会话不存在'));
add('SESSION-R022', 'peer', x => { x.fault = 'touch'; deny(x); });
add('SESSION-R023', 'peer', x => {
  x.fault = 'revoke'; x.requests[0].expectedStatus = 500; x.requests[0].expectedEnvelope = envelope(50001, '服务器内部错误');
  x.expectedRevokedSessionIds = ['revoked'];
});
add('SESSION-R024', 'peer', x => {
  x.requests[0].headers.authorization = `bEaReR ${tokens.cases.find(item => item.id === 'access-hs512').token}`;
});
add('SESSION-R025', 'peer', x => {
  x.requests.push({ ...structuredClone(x.requests[0]), expectedStatus: 404, expectedEnvelope: envelope(40401, '会话不存在') });
  x.expectedTouches = 2; x.expectedRevokes = 2;
});
add('SESSION-R026', 'peer', x => { x.requests[0].headers = { cookie: `access_token="${token}"` }; });
add('SESSION-R027', 'peer', x => {
  x.requests[0].headers = { cookie: `access_token=; access_token=${token}` };
  deny(x, 401, '请先登录', true);
});
add('SESSION-R028', 'peer', x => { x.requests[0].headers.cookie = 'access_token=; access_token=bad-fixture-token'; });
add('SESSION-R029', 'peer', x => {
  x.requests[0].headers = { authorization: 'Bearer bad-fixture-token' };
  x.requests[0].cookieFields = ['harmless=1', `access_token=${token}`];
});
writeFileSync(new URL('../specifications/scenarios/auth-session-revocation.json', import.meta.url), `${JSON.stringify({
  id: 'AUTH-SESSION-REVOCATION', revision: 1, scope: 'HTTP and JWT with isolated Oracle boundary; not real database or native full-auth acceptance',
  now, keys: tokens.keys, cases
}, null, 2)}\n`);
