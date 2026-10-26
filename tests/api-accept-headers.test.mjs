import assert from 'node:assert/strict';
import { test } from 'node:test';
import { withJsonAccept } from '../app/utils/apiHeaders.ts';

test('API requests default to JSON without changing caller headers', () => {
  const input = Object.freeze({
    Authorization: 'Bearer fixture',
    Cookie: 'access_token=fixture'
  });
  const actual = withJsonAccept(input);
  assert.deepEqual(actual, {
    ...input,
    Accept: 'application/json'
  });
  assert.notEqual(actual, input);
  assert.deepEqual(withJsonAccept(), {
    Accept: 'application/json'
  });
});

for (const name of ['Accept', 'accept', 'ACCEPT', 'aCcEpT']) {
  for (const value of ['text/event-stream', 'application/problem+json', '']) {
    test(`preserves explicit ${name}=${JSON.stringify(value)}`, () => {
      const input = Object.freeze({ [name]: value, 'X-Trace': 'fixture' });
      const actual = withJsonAccept(input);
      assert.deepEqual(actual, input);
      assert.equal(Object.keys(actual).filter(key => key.toLowerCase() === 'accept').length, 1);
    });
  }
}

test('existing multiple Accept spellings are preserved without another default', () => {
  const input = { accept: 'text/plain', ACCEPT: 'text/event-stream' };
  assert.deepEqual(withJsonAccept(input), input);
});
