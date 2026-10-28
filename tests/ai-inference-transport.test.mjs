import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { test } from 'node:test';
import { AiInferenceTransport } from '../server/services/ai/inference-transport.ts';
import { listenForFetch } from './helpers/loopback-listener.mjs';

const fixture = JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-inference-transport.json', import.meta.url)));
assert.equal(fixture.cases.length, 55);
const historyFixture = JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-tool-history.json', import.meta.url)));
assert.equal(historyFixture.cases.length, 24);
async function serverFor(handler, run) {
  const server = createServer(handler);
  const origin = await listenForFetch(server);
  try { await run(origin); }
  finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}
function safeError(code) {
  return error => {
    assert.equal(error.code, code);
    assert.equal(error.cause, undefined);
    assert(!String(error).includes('never-print'));
    assert(!String(error).includes('http'));
    return true;
  };
}
for (const item of [...fixture.cases, ...historyFixture.cases]) {
  test(`AI inference transport: ${item.id}`, async () => {
    let calls = 0;
    await serverFor(async (req, res) => {
      calls++;
      assert.equal(req.method, 'POST');
      assert.equal(req.url, item.expectedPath);
      assert.equal(req.headers.authorization, item.expectedAuthorization);
      assert.equal(req.headers['accept-encoding'], 'identity');
      assert.equal(req.headers.cookie, undefined);
      let body = '';
      for await (const chunk of req) body += chunk;
      if (item.expectedBody) assert.deepEqual(JSON.parse(body), item.expectedBody);
      res.writeHead(item.status, { 'content-type': 'application/json' });
      res.end(item.responseText ?? JSON.stringify(item.response));
    }, async origin => {
      const selection = { ...item.selection, baseUrl: origin + new URL(item.selection.baseUrl).pathname };
      const transport = new AiInferenceTransport(ref => item.credentials[ref]);
      if (item.expectedError) await assert.rejects(transport.infer(selection, item.request), safeError(item.expectedError));
      else assert.deepEqual(await transport.infer(selection, item.request), item.expected);
    });
    assert.equal(calls, item.noNetwork ? 0 : 1);
  });
}

const base = fixture.cases[1];
test('provider tool proposal can be sent back with its result on both adapters', async () => {
  for (const adapter of ['ollama','openai-compatible']) {
    const first=fixture.cases.find(v=>v.id===(adapter==='ollama'?'TRANSPORT-O03':'TRANSPORT-C03'));
    const last=fixture.cases.find(v=>v.id===(adapter==='ollama'?'TRANSPORT-O01':'TRANSPORT-C01'));
    let count=0;
    await serverFor(async (req,res)=>{
      let data='';for await(const chunk of req)data+=chunk;const body=JSON.parse(data);count++;
      if(count===2){const call=body.messages.at(-2).tool_calls[0], result=body.messages.at(-1);assert.equal(call.function.name,'search_public');assert.equal(result.role,'tool');assert.equal(result.content,'synthetic tool result');if(adapter==='ollama'){assert.equal(result.tool_name,'search_public');assert.deepEqual(call.function.arguments,first.expected.toolCalls[0].arguments);}else{assert.equal(result.tool_call_id,'call-1');assert.deepEqual(JSON.parse(call.function.arguments),first.expected.toolCalls[0].arguments);}}
      res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify(count===1?first.response:last.response));
    },async origin=>{
      const selection={...first.selection,baseUrl:origin+new URL(first.selection.baseUrl).pathname,apiKeyEnv:null};const transport=new AiInferenceTransport();
      const initial=await transport.infer(selection,first.request);assert.equal(initial.finishReason,'tool-calls');
      const request={...first.request,messages:[...first.request.messages,{role:'assistant',content:initial.text,toolCalls:initial.toolCalls},{role:'tool',content:'synthetic tool result',toolCallId:initial.toolCalls[0].id}]};
      const answer=await transport.infer(selection,request);assert.equal(answer.finishReason,'stop');assert.equal(answer.text,'合成回复');
    });
    assert.equal(count,2);
  }
});
const selectionFor = origin => ({ ...structuredClone(base.selection), baseUrl: `${origin}/prefix/v1` });
test('transport boundary: rejects non-JSON and malformed request values before credentials', async () => {
  const cyclic = {}; cyclic.self = cyclic;
  const invalid = [undefined, { messages: [,] }, { messages: [{ role: ['user'], content: '' }] },
    { ...base.request, extra: undefined }, { ...base.request, tools: null },
    { ...base.request, responseSchema: { type: 'object', x: NaN } },
    { ...base.request, responseSchema: { type: 'object', x: cyclic } },
    { ...base.request, responseSchema: { type: 'object', toJSON() { return {}; } } },
    { ...base.request, responseSchema: { type: 'object', x: new Date() } },
    { messages: [{ role: 'user', content: 'x'.repeat(1048576) }] }];
  for (const request of invalid) {
    let resolved = false;
    const transport = new AiInferenceTransport(() => { resolved = true; return 'never-print'; });
    await assert.rejects(transport.infer({ ...base.selection, apiKeyEnv: 'KEY' }, request), safeError('INVALID_REQUEST'));
    assert.equal(resolved, false);
  }
});
test('transport boundary: response validation', async () => {
  const variants = [
    { body: Buffer.from([0xff]), code: 'INVALID_PROVIDER_RESPONSE' },
    { body: '{', code: 'INVALID_PROVIDER_RESPONSE' },
    { body: JSON.stringify({ ...base.response, usage: { prompt_tokens: null } }), code: 'INVALID_PROVIDER_RESPONSE' },
    { body: JSON.stringify(base.response), encoding: 'gzip', code: 'INVALID_PROVIDER_RESPONSE' },
    { body: 'x'.repeat(1048577), code: 'RESPONSE_TOO_LARGE' },
    { status: 302, body: 'never-print-provider', code: 'PROVIDER_REJECTED' },
    { status: 500, body: 'never-print-provider', code: 'PROVIDER_REJECTED' }
  ];
  for (const variant of variants) {
    let count = 0;
    await serverFor((req, res) => {
      count++;
      res.writeHead(variant.status ?? 200, { ...(variant.encoding ? { 'content-encoding': variant.encoding } : {}), location: '/followed' });
      res.write(variant.body); res.end();
    }, async origin => {
      await assert.rejects(new AiInferenceTransport().infer(selectionFor(origin), base.request), safeError(variant.code));
    });
    assert.equal(count, 1);
  }
});
test('transport boundary: timeout and cancellation cover body waits', async () => {
  for (const phase of ['headers', 'body']) {
    await serverFor((req, res) => { if (phase === 'body') { res.writeHead(200); res.write('{'); } }, async origin => {
      await assert.rejects(new AiInferenceTransport(undefined, 30).infer(selectionFor(origin), base.request), safeError('TIMEOUT'));
      const controller = new AbortController();
      const pending = new AiInferenceTransport().infer(selectionFor(origin), base.request, controller.signal);
      setTimeout(() => controller.abort(), 30);
      await assert.rejects(pending, safeError('CANCELLED'));
    });
  }
  const controller = new AbortController(); controller.abort();
  await assert.rejects(new AiInferenceTransport(() => { assert.fail('resolver called'); }).infer(base.selection, base.request, controller.signal), safeError('CANCELLED'));
});
test('transport boundary: resolver failures and unavailable provider stay safe', async () => {
  await assert.rejects(new AiInferenceTransport(() => { throw new Error('never-print-secret http://private'); }).infer({ ...base.selection, apiKeyEnv: 'KEY' }, base.request), safeError('MISSING_CREDENTIAL'));
  await assert.rejects(new AiInferenceTransport().infer({ ...base.selection, baseUrl: 'http://127.0.0.1:1' }, base.request), safeError('PROVIDER_UNAVAILABLE'));
  for (const value of [0, null, 300001, 1.5]) assert.throws(() => new AiInferenceTransport(undefined, value), safeError('INVALID_REQUEST'));
});
test('transport boundary: snapshots and requests detach before network and preserve integral usage', async () => {
  let seen;
  await serverFor(async (req, res) => {
    let body = ''; for await (const chunk of req) body += chunk;
    seen = JSON.parse(body);
    res.end(JSON.stringify({ ...base.response, usage: { prompt_tokens: 1.0, completion_tokens: 0 } }));
  }, async origin => {
    const selection = selectionFor(origin); const request = structuredClone(base.request);
    const pending = new AiInferenceTransport().infer(selection, request);
    selection.baseUrl = 'http://127.0.0.1:1'; selection.model = 'changed'; selection.capabilities.length = 0;
    request.messages[0].content = 'changed';
    const result = await pending;
    assert.deepEqual(result.usage, { inputTokens: 1, outputTokens: 0 });
  });
  assert.equal(seen.model, base.selection.model);
  assert.deepEqual(seen.messages, base.request.messages);
});
test('transport boundary: Unicode scalar strings and JSON keys', async () => {
  for (const text of ['\ud800', '\udc00', 'prefix\ud800suffix']) {
    await assert.rejects(new AiInferenceTransport().infer(base.selection, { messages: [{ role: 'user', content: text }] }), safeError('INVALID_REQUEST'));
    await assert.rejects(new AiInferenceTransport().infer(base.selection, { ...base.request, responseSchema: { type: 'object', [text]: 'value' } }), safeError('INVALID_REQUEST'));
  }
  await serverFor((req, res) => res.end('{"choices":[{"index":0,"message":{"role":"assistant","content":"\\ud800"},"finish_reason":"stop"}]}'), async origin => {
    await assert.rejects(new AiInferenceTransport().infer(selectionFor(origin), base.request), safeError('INVALID_PROVIDER_RESPONSE'));
  });
});
test('transport boundary: hostile objects and array keys cannot escape validation', async () => {
  const proxy = new Proxy({}, { getPrototypeOf() { throw new Error('never-print http://private'); } });
  await assert.rejects(new AiInferenceTransport().infer(base.selection, proxy), safeError('INVALID_REQUEST'));
  const sparse = Array(1); sparse['4294967295'] = null;
  let resolved = false;
  await assert.rejects(new AiInferenceTransport(() => { resolved = true; return 'never-print'; }).infer({ ...base.selection, apiKeyEnv: 'KEY' }, { ...base.request, responseSchema: { type: 'object', extra: sparse } }), safeError('INVALID_REQUEST'));
  assert.equal(resolved, false);
});
