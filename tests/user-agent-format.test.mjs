import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { transform } from 'esbuild';

const tsSource = readFileSync(new URL('../app/utils/userAgent.ts', import.meta.url), 'utf8');
const { code } = await transform(tsSource, { loader: 'ts', format: 'esm' });
const { parseUserAgent, formatSecurityMessage } = await import(
  `data:text/javascript;base64,${Buffer.from(code).toString('base64')}`
);

test('parseUserAgent parses Chrome, Edge, Safari, iOS, Firefox', () => {
  assert.equal(
    parseUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/158.0.0.0 Safari/537.36')?.summary,
    'Chrome · Windows'
  );
  assert.equal(
    parseUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/158.0.0.0 Safari/537.36 Edg/158.0.0.0')?.summary,
    'Edge · Windows'
  );
  assert.equal(
    parseUserAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1')?.summary,
    'Safari · iOS'
  );
  assert.equal(
    parseUserAgent('Mozilla/5.0 (X11; Linux x86_64) Gecko/20100101 Firefox/128.0')?.summary,
    'Firefox · Linux'
  );
  assert.equal(parseUserAgent('Plain string'), null);
});

test('formatSecurityMessage shortens UA strings in login alerts', () => {
  const raw = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/158.0.0.0 Safari/537.36';
  const result = formatSecurityMessage(`检测到来自 ${raw} 的登录`);
  assert.equal(result.text, '检测到来自 Chrome · Windows 的登录');
  assert.equal(result.rawUserAgent, raw);
  assert.equal(result.summary, 'Chrome · Windows');
});
