import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import assert from 'node:assert/strict';
import test from 'node:test';
import { runReplay } from '../scripts/benchmark/replay.mjs';
import { openOracleState } from '../scripts/benchmark/oracle-state.mjs';

const digest = value => createHash('sha256').update(value).digest('hex');
const jwt = (userId, sessionId, jti, type) =>
  `eyJhbGciOiJIUzI1NiJ9.${Buffer.from(JSON.stringify({ userId, sessionId, jti, type })).toString('base64url')}.signature`;
const ok = data => ({ code: 200, message: 'success', data, meta: null });

async function fixture(t, names, behavior = {}) {
  const targets = {};
  const states = {};
  for (const [index, name] of names.entries()) {
    const state = states[name] = {
      id: 100 + index,
      post: 200 + index,
      session: `fixture-session-${name}`,
      guard: `password-${name}-do-not-output`,
      at: `2026-03-0${index + 1}T12:00:00.000Z`,
      likes: 0, exists: false, deleted: false, revoked: false,
      rotation: 0, sql: [], requests: [], closed: false, deviceInfo: null,
    };
    const tokens = () => ({
      session_id: state.session,
      access_token: jwt(state.id, state.session, `${name}-access-${state.rotation}`, 'access'),
      refresh_token: jwt(state.id, state.session, `${name}-refresh-${state.rotation}`, 'refresh'),
      refresh_token_expires_at: state.at,
    });
    const profile = () => ({ user_id: state.id, username: 'fixture', created_at: state.at, counters: [0, 1] });
    const server = createServer(async (req, res) => {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : null;
      const uri = new URL(req.url, 'http://localhost');
      const path = uri.pathname;
      state.requests.push([req.method, path]);
      const send = (status, data) => {
        res.writeHead(status, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(data));
      };
      if (path === '/api/v2/auth/tokens' && req.method === 'POST') {
        assert.equal(body.password, state.guard);
        assert.match(req.headers['x-device-info'], /^nekotribe-parity-session-/u);
        state.deviceInfo = req.headers['x-device-info'];
        return send(200, ok({ user: profile(), tokens: tokens() }));
      }
      if (path === '/api/v2/auth/tokens/current' && req.method === 'PATCH') {
        if (body.refresh_token !== tokens().refresh_token) {
          return send(401, { code: 401, message: 'invalid refresh', data: null, meta: null });
        }
        state.rotation += 1;
        return send(200, ok(tokens()));
      }
      if (path === '/api/v2/auth/tokens/current' && req.method === 'DELETE') {
        assert.equal(body.refresh_token, tokens().refresh_token);
        state.revoked = true;
        return send(200, ok(null));
      }
      if (req.headers.authorization !== `Bearer ${tokens().access_token}`) {
        return send(401, { code: 401, message: 'invalid access', data: null, meta: null });
      }
      if (path === '/api/v2/users/me' || path === `/api/v2/users/${state.id}`) {
        return send(200, ok(profile()));
      }
      if (path === '/api/v2/posts' && req.method === 'POST') {
        assert.match(body.content, /^nekotribe-parity-/u);
        state.exists = true;
        state.content = body.content;
        return send(200, ok({ post_id: state.post }));
      }
      if (path === '/api/v2/posts' && req.method === 'GET') {
        assert.equal(uri.searchParams.get('q'), state.content);
        if (behavior[name]?.badJson) {
          res.writeHead(504, { 'Content-Type': 'text/plain' });
          res.end(`do not output ${state.guard}`);
          return;
        }
        return send(behavior[name]?.feedStatus ?? 200, ok({
          posts: [{ post_id: state.post, author_id: state.id, content: state.content, created_at: state.at,
            note: behavior[name]?.note ?? null }],
        }));
      }
      if (path === `/api/v2/posts/${state.post}/likes`) {
        state.likes = req.method === 'DELETE' ? 0 : behavior[name]?.duplicatedLike ? state.likes + 1 : 1;
        return send(200, ok({ count: req.method === 'DELETE' ? 0 : 1 }));
      }
      if (path === `/api/v2/posts/${state.post}` && req.method === 'DELETE') {
        if (behavior[name]?.failDelete && !state.failedDelete) {
          state.failedDelete = true;
          return send(503, ok(null));
        }
        state.deleted = true;
        return send(200, ok(null));
      }
      return send(404, ok(null));
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise(resolve => server.close(resolve)));
    targets[name] = {
      account: `account-${name}-redacted`, password: state.guard,
      baseUrl: `http://127.0.0.1:${server.address().port}`,
      oracle: { user: name, password: `oracle-secret-${name}`, connectString: `unknown-db-${name}` },
    };
    state.tokens = tokens;
  }
  const driver = {
    OUT_FORMAT_ARRAY: 4001,
    async getConnection(config) {
      const name = config.user;
      if (behavior[name]?.noOracle) throw new Error(`raw DSN ${config.connectString}`);
      const state = states[name];
      assert.equal(config.connectTimeout, 1);
      return {
        async execute(sql, binds, options) {
          assert.equal(this.callTimeout, 1000);
          assert.equal(options.outFormat, 4001);
          assert.match(sql, /^SELECT /u);
          assert.equal(binds.user_id, state.id);
          assert.ok(!sql.includes(state.session));
          assert.ok(!state.content || !sql.includes(state.content));
          state.sql.push(sql);
          if (sql.includes('FROM n_auth_sessions')) {
            assert.equal(binds.session_id, state.session);
            assert.equal(binds.device_info, state.deviceInfo);
            if (sql.includes('revoked_at IS NOT NULL')) return { rows: [[Number(state.revoked)]] };
            assert.equal(binds.access_jti, `${name}-access-${state.rotation}`);
            assert.equal(binds.refresh_hash, digest(state.tokens().refresh_token));
            if (state.rotation) {
              assert.equal(binds.original_jti, `${name}-access-0`);
              assert.equal(binds.original_hash, digest(jwt(state.id, state.session, `${name}-refresh-0`, 'refresh')));
            }
            return { rows: [[1]] };
          }
          if (sql.includes('FROM n_post_likes')) {
            assert.equal(binds.post_id, state.post);
            return { rows: [[state.likes]] };
          }
          assert.equal(binds.content, state.content);
          if (sql.startsWith('SELECT post_id')) return { rows: state.exists && !state.deleted ? [[state.post]] : [] };
          assert.equal(binds.post_id, state.post);
          return { rows: [[Number(state.exists && state.deleted === sql.includes('is_deleted = 1'))]] };
        },
        async close() { state.closed = true; },
      };
    },
  };
  return {
    states, targets,
    run: () => runReplay(targets, { timeoutMs: 1000 }, {
      openOracleState: (config, options) => openOracleState(config, options, { driver }),
    }),
  };
}

test('canonical replay compares three isolated HTTP targets and bounded SELECT state', async t => {
  const suite = await fixture(t, ['nuxt', 'go', 'rust']);
  const result = await suite.run();
  assert.deepEqual(result.differences, []);
  assert.equal(result.passed, true);
  for (const state of Object.values(suite.states)) {
    assert.equal(state.sql.length, 9);
    assert.equal(state.deleted, true);
    assert.equal(state.revoked, true);
    assert.equal(state.closed, true);
  }
  const normalized = result.targets.rust.cases[0].steps[0];
  assert.deepEqual(normalized.body.data.user, { user_id: '$userId', username: 'fixture', created_at: '$timestamp', counters: [0, 1] });
  assert.equal(normalized.body.data.tokens.refresh_token, '[redacted]');
  assert.equal(normalized.body.data.tokens.session_id, '$sessionId');
  const report = JSON.stringify(result);
  assert.doesNotMatch(report, /do-not-output|oracle-secret|unknown-db|eyJhbGci|nekotribe-parity|fixture-session/u);
});

test('replay continues independent fixtures and reports status, JSON, persistence and cleanup', async t => {
  const suite = await fixture(t, ['nuxt', 'go', 'rust'], {
    nuxt: { noOracle: true }, go: { duplicatedLike: true, note: '2026-03-01T12:00:00.000Z', failDelete: true },
    rust: { badJson: true },
  });
  const result = await suite.run();
  assert.equal(result.passed, false);
  assert.equal(suite.states.nuxt.requests.length, 0);
  assert.ok(result.differences.some(item => item.target === 'nuxt' && item.reason === 'oracle-unavailable'));
  assert.ok(result.differences.some(item => item.target === 'go' && item.stepId === 'like-again' && item.kind === 'probe'));
  assert.ok(result.differences.some(item => item.target === 'rust' && item.stepId === 'read-feed' && item.kind === 'status' && item.actual === 504));
  assert.ok(result.differences.some(item => item.target === 'rust' && item.stepId === 'read-feed' && item.kind === 'response'));
  assert.equal(result.targets.go.cases[1].steps[2].body.data.posts[0].note, '2026-03-01T12:00:00.000Z');
  for (const state of [suite.states.go, suite.states.rust]) {
    assert.equal(state.deleted && state.revoked && state.closed, true);
  }
  const report = JSON.stringify(result);
  assert.doesNotMatch(report, /do-not-output|oracle-secret|unknown-db|raw DSN|eyJhbGci/u);
});
