import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { AiModelRouter } from '../server/services/ai/model-configuration.ts';

const fixture = JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-model-config.json', import.meta.url)));
assert.equal(fixture.cases.length, 52);
for (const item of fixture.cases) {
  test(`AI model configuration: ${item.id}`, () => {
    let router;
    let before;
    const config = structuredClone(item.config);
    function execute() {
      router = new AiModelRouter(config);
      if (item.action === 'replace') {
        before = router.select(item.role);
        router.replace(item.nextConfig, item.expectedRevision);
      } else if (item.action === 'isolation') {
        const selected = router.select(item.role);
        config.models[1].model = 'mutated-input';
        try { selected.capabilities[0] = 'vision'; } catch (error) { assert(error instanceof TypeError); }
        try { selected.model = 'mutated-selection'; } catch (error) { assert(error instanceof TypeError); }
      }
      return router.select(item.role, item.requiredCapabilities ?? []);
    }
    if (item.expectedError) {
      assert.throws(execute, error => {
        assert.equal(error.code, item.expectedError);
        assert(!error.message.includes('never-print-fixture'));
        assert(!error.message.includes('https://'));
        return true;
      });
      if (item.expectedAfterError) assert.deepEqual(router.select(item.role), item.expectedAfterError);
    } else {
      assert.deepEqual(execute(), item.expected);
      if (item.expectedBefore) assert.deepEqual(before, item.expectedBefore);
    }
  });
}

test('sparse JavaScript input arrays are rejected with safe configuration errors', () => {
  for (const field of ['providers', 'models']) {
    const config = structuredClone(fixture.cases[0].config);
    delete config[field][0];
    assert.throws(() => new AiModelRouter(config), error => error.code === 'INVALID_CONFIGURATION');
  }
  const config = structuredClone(fixture.cases[0].config);
  config.models[0].capabilities = Array(1);
  assert.throws(() => new AiModelRouter(config), error => error.code === 'INVALID_CONFIGURATION');
});
test('sparse requested capabilities cannot bypass capability checks', () => {
  const router = new AiModelRouter(fixture.cases[0].config);
  assert.throws(() => router.select('knowledge', Array(1)), error => error.code === 'UNSUPPORTED_CAPABILITY');
});
