// Writes fixture posts/media. Run only against the explicitly disposable test stack.
import assert from 'node:assert/strict';
const base = process.env.NEKO_RUNTIME_TEST_BASE;
const password = process.env.NEKO_RUNTIME_TEST_PASSWORD;
if (process.env.NEKO_RUNTIME_TEST_DISPOSABLE !== 'true' || !base || !password) {
  throw new Error('Explicit disposable test base and fixture password are required.');
}
const endpoint = new URL(base);
assert(['http:', 'https:'].includes(endpoint.protocol));
assert(!endpoint.username && !endpoint.password && endpoint.pathname === '/');
const observations = [];
let access; let refresh;
async function request(path, { method = 'GET', body, status = 200, authenticated = true } = {}) {
  const multipart = body instanceof FormData;
  const response = await fetch(new URL(path, endpoint), {
    method, signal: AbortSignal.timeout(30000), headers: {
      Accept: 'application/json',
      ...(body && !multipart ? { 'Content-Type': 'application/json' } : {}),
      ...(authenticated && access ? { Authorization: `Bearer ${access}` } : {})
    }, ...(body ? { body: multipart ? body : JSON.stringify(body) } : {})
  });
  const value = await response.json();
  assert.equal(response.status, status, `${method} ${path}: ${value.message ?? value.statusMessage ?? 'unexpected status'}`);
  if (status === 200 && path.startsWith('/api/v2/')) assert.equal(value.code, 200);
  observations.push(`${method} ${path} -> ${status}`);
  return { response, value };
}
await request('/api/health', { authenticated: false });
const unauthorized = await request('/api/v2/users/me', { status: 401, authenticated: false });
assert.equal(unauthorized.value.data.code, 40101);
const login = await request('/api/v2/auth/tokens', { method: 'POST', authenticated: false,
  body: { account: 'runtime_t16', password } });
assert(login.value.data.tokens.access_token && login.value.data.tokens.refresh_token);
assert(login.response.headers.getSetCookie().some(cookie => cookie.startsWith('access_token=')));
access = login.value.data.tokens.access_token; refresh = login.value.data.tokens.refresh_token;
const me = await request('/api/v2/users/me');
assert.equal(me.value.data.username, 'runtime_t16');
await request('/api/v2/users/me/settings');
await request('/api/v2/notifications');
await request('/api/v2/groups');
const marker = `T16 ${Date.now()}`;
const created = await request('/api/v2/posts', { method: 'POST', body: { content: marker, visibility: 'public', tag_names: ['t16-fixture'] } });
const postId = created.value.data.post_id;
assert(Number.isSafeInteger(postId));
const updated = await request(`/api/v2/posts/${postId}`, { method: 'PATCH', body: { content: `${marker} updated` } });
assert.equal(updated.value.data.content, `${marker} updated`);
assert.equal(updated.value.data.visibility, 'public');
assert(updated.value.data.tags.includes('t16-fixture'));
const unchanged = await request(`/api/v2/posts/${postId}`, { method: 'PATCH', body: {} });
assert.equal(unchanged.value.data.content, `${marker} updated`);
const cleared = await request(`/api/v2/posts/${postId}`, { method: 'PUT', body: { tag_names: [] } });
assert.equal(cleared.value.data.tags.length, 0);
assert.equal(cleared.value.data.content, `${marker} updated`);
await request(`/api/v2/posts/${postId}`, { authenticated: false });
const upload = new FormData();
upload.set('file', new Blob([Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ8sAAAAASUVORK5CYII=', 'base64')], { type: 'image/png' }), 't16.png');
const media = await request('/api/v2/media', { method: 'POST', body: upload });
assert(Number.isSafeInteger(media.value.data.media_id));
const file = await fetch(new URL(media.value.data.public_url, endpoint), { signal: AbortSignal.timeout(15000) });
assert.equal(file.status, 200); assert.match(file.headers.get('content-type'), /image\/png/);
assert((await file.arrayBuffer()).byteLength > 0);
observations.push('uploaded image publicly readable');
const refreshed = await request('/api/v2/auth/tokens/current', { method: 'PATCH', authenticated: false, body: { refresh_token: refresh } });
access = refreshed.value.data.access_token; refresh = refreshed.value.data.refresh_token;
assert(access && refresh);
await request('/api/v2/users/me');
await request('/api/v2/auth/tokens/current', { method: 'DELETE', body: { refresh_token: refresh } });
await request('/api/v2/users/me', { status: 401 });
const preflight = await fetch(new URL('/api/v2/posts', endpoint), { method: 'OPTIONS', headers: {
  Origin: 'http://127.0.0.1:30004', 'Access-Control-Request-Method': 'PATCH',
  'Access-Control-Request-Headers': 'authorization,content-type,x-request-id,x-client-platform,x-device-fingerprint,x-device-info'
}, signal: AbortSignal.timeout(15000) });
assert([200, 204].includes(preflight.status));
assert.equal(preflight.headers.get('access-control-allow-origin'), 'http://127.0.0.1:30004');
assert.equal(preflight.headers.get('access-control-allow-credentials'), 'true');
observations.push('credentialed CORS preflight uses exact allowed origin');
console.log(JSON.stringify({ base: endpoint.origin, observations, postId, mediaId: media.value.data.media_id }));
