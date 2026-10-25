// Optional semantic audit using Ajv already installed by the Nuxt dependency tree.
// Core offline checks and tests/contracts.test.mjs require only Node built-ins.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Ajv = require('ajv');
const spec = JSON.parse(readFileSync(new URL('../../doc/v2.openapi.json', import.meta.url)));
const report = JSON.parse(readFileSync(new URL('../../docs/audits/2026-09-10-t11-null-schema-repair.json', import.meta.url)));

test('79 repaired nullable schemas accept documented values and reject wrong types', () => {
  const ajv = new Ajv({ nullable: true, unknownFormats: 'ignore', strictKeywords: false });
  ajv.addSchema(spec, 'https://neko.invalid/openapi');
  let assertions = 0;
  assert.equal(report.records.length, 79);
  for (const record of report.records) {
    const validate = ajv.compile({ $ref: 'https://neko.invalid/openapi' + record.pointer });
    assert.equal(validate(null), true, record.pointer + ': null should pass');
    assertions++;
    if (record.after.enum) {
      for (const value of [{}, '', 0, false, []]) {
        assert.equal(validate(value), false, record.pointer + ': only null');
        assertions++;
      }
    } else if (record.after.type === 'number') {
      assert.equal(validate(42), true, record.pointer);
      assert.equal(validate('42'), false, record.pointer);
      assertions += 2;
    } else if (record.after.type === 'string') {
      assert.equal(validate('value'), true, record.pointer);
      assert.equal(validate(42), false, record.pointer);
      assertions += 2;
    } else if (record.pointer.endsWith('/metadata')) {
      for (const value of [42, 'value', false, {}, [], [{ a: true }]]) {
        assert.equal(validate(value), true, record.pointer);
        assertions++;
      }
    } else {
      const message = { message_id: 3, content: 'hello', author_name: 'Name', created_at: '2026-09-10T00:00:00Z' };
      assert.equal(validate(message), true, record.pointer);
      assert.equal(validate({}), false, record.pointer);
      assertions += 2;
    }
  }
  assert.equal(assertions, 304);
});
