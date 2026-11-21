import assert from 'node:assert/strict';
import {test} from 'node:test';
import {request,vectors,marker} from './helpers/settings-http.mjs';

for (const method of ['GET', 'PATCH']) {
  for (const vector of vectors.cases) test(method + ' common native ' + vector.id, async () => {
    const result = await request({ ...vector, method });
    assert.equal(result.status, vector.status);
    assert.equal(result.headers.get('cache-control'), 'private, no-store');
    if (vector.message) assert.equal((result.status === 200 ? result.body : result.body.data).message, vector.message);
    assert(!JSON.stringify(result.body).includes(marker));
    assert(!result.state.errors.some(error => String(error).includes(marker)));
    if (method === 'GET') assert.equal(result.state.cacheCalls, 0);
    if (vector.status === 404) {
      assert.equal(result.state.rollbacks, 1);
      assert.equal(result.state.commits, 0);
      if (vector.mode === 'missing-user') assert(!result.state.calls.some(call => call.sql.includes('MERGE')));
    }
    if (vector.status === 200) {
      assert.equal(Object.keys(result.body.data).length, 14);
      assert.equal(result.body.data.user_id, 42);
      assert.equal(result.state.commits, 1);
      assert.equal(result.state.rollbacks, 0);
      const writes = result.state.calls.filter(call => /MERGE INTO|UPDATE n_user_settings/.test(call.sql));
      assert(writes.length > 0);
      assert(writes.every(call => call.options.autoCommit === false));
      assert.equal(result.state.calls.filter(call => call.sql.includes('FOR UPDATE')).length, 1);
    }
  });
  for (const vector of vectors.mappingCases) test(method + ' NUMBER mapping ' + vector.id, async () => {
    const result = await request({ method, mapping: vector });
    assert.equal(result.status, 200);
    assert.equal(result.body.data.two_factor_enabled, vector.expectedFlag);
    assert.equal(result.body.data.login_alerts, vector.expectedFlag);
    assert.equal(result.body.data.ai_sentiment_return_probabilities, vector.expectedProbabilities);
    assert.equal(result.body.data.ai_sentiment_top_k, vector.expectedTop);
  });
  for (const mode of ['lock', 'merge', 'read', 'commit', 'rollback', 'open', 'close', 'wrong-lock', 'wrong-row']) test(method + ' isolated failure ' + mode, async () => {
    const result = await request({ method, mode });
    assert.equal(result.status, 500);
    assert.equal(result.headers.get('cache-control'), 'private, no-store');
    assert(!JSON.stringify(result.body).includes(marker));
    assert(!result.state.errors.some(error => String(error).includes(marker)));
    if (!['open', 'close'].includes(mode)) assert.equal(result.state.rollbacks, 1);
    assert.equal(result.state.commits, ['commit', 'close'].includes(mode) ? 1 : 0);
  });
}
test('invalid PATCH validates before initialization or any transaction write', async () => {
  for (const body of [{ profile_visibility: 'followers' }, { two_factor_enabled: false }, { ai_sentiment_top_k: 11 }, { ai_sentiment_model_id: 'x'.repeat(129) }]) {
    const result = await request({ method: 'PATCH', body });
    assert.equal(result.status, 400);
    assert.equal(result.state.calls.length, 0);
    assert.equal(result.state.commits, 0);
  }
});
test('PATCH update failure rolls back the initialization transaction', async () => {
  const result = await request({ method: 'PATCH', mode: 'update', body: { login_alerts: true } });
  assert.equal(result.status, 500);
  assert.equal(result.state.rollbacks, 1);
  assert.equal(result.state.commits, 0);
});
test('revoked and unavailable authentication remain private without reading settings', async () => {
  for (const mode of ['revoked', 'auth-error']) {
    const result = await request({ mode });
    assert.equal(result.status, 401);
    assert.equal(result.headers.get('cache-control'), 'private, no-store');
    assert.equal(result.state.calls.length, 0);
  }
});
