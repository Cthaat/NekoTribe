import { writeFileSync } from 'node:fs';

// Public synthetic inputs only. Never read process.env or project runtime data.
const selection = {
  configurationRevision: 1, role: 'knowledge', profileId: 'prototype', providerId: 'local',
  adapter: 'ollama', baseUrl: 'http://127.0.0.1:11434/prefix', model: 'arbitrary-model:v1',
  apiKeyEnv: null, capabilities: ['structured-output', 'tools'], contextWindowTokens: 8192, maxOutputTokens: 512
};
const message = { role: 'user', content: '公开测试问题' };
const tool = { name: 'search_public', description: 'Search public posts', parameters: { type: 'object', properties: { query: { type: 'string' }, toJSON: { type: 'string' } }, required: ['query'], additionalProperties: false } };
const schema = { type: 'object', properties: { summary: { type: 'string' } }, required: ['summary'], additionalProperties: false };
const request = { messages: [message] };
const success = { text: '合成回复', toolCalls: [], finishReason: 'stop', usage: { inputTokens: 7, outputTokens: 3 } };
const ollama = { done: true, done_reason: 'stop', message: { role: 'assistant', content: '合成回复', thinking: 'never-return-this' }, prompt_eval_count: 7, eval_count: 3 };
const compatible = { choices: [{ index: 0, message: { role: 'assistant', content: '合成回复', reasoning: 'never-return-this' }, finish_reason: 'stop' }], usage: { prompt_tokens: 7, completion_tokens: 3 } };
const cases = [];
function add(id, adapter, changes = () => {}) {
  const selected = { ...selection, adapter, baseUrl: adapter === 'ollama' ? selection.baseUrl : 'http://127.0.0.1:8000/prefix/v1' };
  const body = adapter === 'ollama'
    ? { model: selected.model, messages: [message], stream: false, options: { num_predict: 512, num_ctx: 8192 } }
    : { model: selected.model, messages: [message], stream: false, n: 1, max_tokens: 512 };
  const item = structuredClone({ id, selection: selected, request, credentials: {}, expectedPath: adapter === 'ollama' ? '/prefix/api/chat' : '/prefix/v1/chat/completions', expectedBody: body, status: 200, response: adapter === 'ollama' ? ollama : compatible, expected: success });
  changes(item);
  if (item.expectedError) delete item.expected;
  cases.push(item);
}
function plain(id, adapter, modify) { add(id, adapter, modify ?? (() => {})); }
function invalid(id, modify, code = 'INVALID_REQUEST') { add(id, 'ollama', x => { modify(x); x.expectedError = code; x.noNetwork = true; delete x.expectedBody; }); }
plain('TRANSPORT-O01', 'ollama');
plain('TRANSPORT-C01', 'openai-compatible');
for (const adapter of ['ollama', 'openai-compatible']) {
  const tag = adapter === 'ollama' ? 'O' : 'C';
  plain(`TRANSPORT-${tag}02`, adapter, x => {
    x.selection.apiKeyEnv = 'AI_TEST_KEY'; x.credentials.AI_TEST_KEY = 'synthetic-key';
    x.expectedAuthorization = 'Bearer synthetic-key';
  });
  plain(`TRANSPORT-${tag}03`, adapter, x => {
    x.request.tools = [tool];
    x.expectedBody.tools = [{ type: 'function', function: tool }];
    const call = { name: tool.name, arguments: { query: '公开内容', toJSON: 'ordinary JSON data' } };
    if (adapter === 'ollama') {
      x.response.message.content = '';
      x.response.message.tool_calls = [{ function: call }];
    } else {
      x.response.choices[0].message.content = null;
      x.response.choices[0].message.tool_calls = [{ id: 'call-1', type: 'function', function: { ...call, arguments: JSON.stringify(call.arguments) } }];
      x.response.choices[0].finish_reason = 'tool_calls';
    }
    x.expected.text = ''; x.expected.toolCalls = [{ id: adapter === 'ollama' ? 'ollama-0' : 'call-1', ...call }]; x.expected.finishReason = 'tool-calls';
  });
  plain(`TRANSPORT-${tag}04`, adapter, x => {
    x.request.responseSchema = schema;
    if (adapter === 'ollama') { x.expectedBody.format = schema; x.response.message.content = '{"summary":"公开摘要"}'; }
    else { x.expectedBody.response_format = { type: 'json_schema', json_schema: { name: 'output', strict: true, schema } }; x.response.choices[0].message.content = '{"summary":"公开摘要"}'; }
    x.expected.text = '{"summary":"公开摘要"}';
  });
  plain(`TRANSPORT-${tag}05`, adapter, x => {
    if (adapter === 'ollama') { delete x.response.prompt_eval_count; delete x.response.eval_count; }
    else delete x.response.usage;
    x.expected.usage = { inputTokens: null, outputTokens: null };
  });
  plain(`TRANSPORT-${tag}06`, adapter, x => {
    if (adapter === 'ollama') x.response.done_reason = 'length'; else x.response.choices[0].finish_reason = 'length';
    x.expected.finishReason = 'length';
  });
  plain(`TRANSPORT-${tag}07`, adapter, x => { x.status = 401; x.response = { error: 'never-return-this synthetic-key' }; x.expectedError = 'PROVIDER_REJECTED'; });
  plain(`TRANSPORT-${tag}08`, adapter, x => {
    x.request.responseSchema = schema;
    if (adapter === 'ollama') { x.expectedBody.format = schema; x.response.message.content = '[]'; }
    else { x.expectedBody.response_format = { type: 'json_schema', json_schema: { name: 'output', strict: true, schema } }; x.response.choices[0].message.content = '[]'; }
    x.expectedError = 'INVALID_PROVIDER_RESPONSE';
  });
  plain(`TRANSPORT-${tag}09`, adapter, x => {
    if (adapter === 'ollama') x.response.eval_count = -1; else x.response.usage.completion_tokens = -1;
    x.expectedError = 'INVALID_PROVIDER_RESPONSE';
  });
  plain(`TRANSPORT-${tag}10`, adapter, x => {
    if (adapter === 'ollama') x.response.message.content = ''; else x.response.choices[0].message.content = '';
    x.expectedError = 'INVALID_PROVIDER_RESPONSE';
  });
}
invalid('TRANSPORT-I01', x => { x.request.url = 'http://never-use'; });
invalid('TRANSPORT-I02', x => { x.request.messages = []; });
invalid('TRANSPORT-I03', x => { x.request.messages[0].role = 'tool'; });
invalid('TRANSPORT-I04', x => { x.request.messages[0].content = null; });
invalid('TRANSPORT-I05', x => { x.request.tools = [tool, tool]; });
invalid('TRANSPORT-I06', x => { x.request.tools = [tool]; x.request.responseSchema = schema; });
invalid('TRANSPORT-I07', x => { x.request.responseSchema = null; });
invalid('TRANSPORT-I08', x => { x.request.tools = [tool]; x.selection.capabilities = []; }, 'UNSUPPORTED_CAPABILITY');
invalid('TRANSPORT-I09', x => { x.request.responseSchema = schema; x.selection.capabilities = []; }, 'UNSUPPORTED_CAPABILITY');
invalid('TRANSPORT-I10', x => { x.selection.apiKeyEnv = 'AI_TEST_KEY'; }, 'MISSING_CREDENTIAL');
invalid('TRANSPORT-I11', x => { x.selection.apiKeyEnv = 'AI_TEST_KEY'; x.credentials.AI_TEST_KEY = 'unsafe\r\nInjected: header'; }, 'MISSING_CREDENTIAL');
invalid('TRANSPORT-I12', x => { x.selection.apiKeyEnv = 'AI_TEST_KEY'; x.credentials.AI_TEST_KEY = 'synthetic-密钥'; }, 'MISSING_CREDENTIAL');
invalid('TRANSPORT-I13', x => { x.selection.apiKeyEnv = 'AI_TEST_KEY'; x.credentials.AI_TEST_KEY = 'contains space'; }, 'MISSING_CREDENTIAL');
invalid('TRANSPORT-I14', x => {
  let nested = {};
  for (let i = 0; i < 64; i++) nested = { nested };
  x.request.responseSchema = { type: 'object', ...nested };
});
plain('TRANSPORT-O11', 'ollama', x => { x.response.done = false; x.expectedError = 'INVALID_PROVIDER_RESPONSE'; });
plain('TRANSPORT-C11', 'openai-compatible', x => { x.response.choices.push(structuredClone(x.response.choices[0])); x.expectedError = 'INVALID_PROVIDER_RESPONSE'; });
for (const adapter of ['ollama', 'openai-compatible']) {
  plain(`TRANSPORT-${adapter === 'ollama' ? 'O' : 'C'}12`, adapter, x => {
    const call = { name: 'unregistered_tool', arguments: {} };
    if (adapter === 'ollama') x.response.message.tool_calls = [{ function: call }];
    else { x.response.choices[0].message.tool_calls = [{ id: 'call-1', type: 'function', function: { ...call, arguments: '{}' } }]; x.response.choices[0].finish_reason = 'tool_calls'; }
    x.expectedError = 'INVALID_PROVIDER_RESPONSE';
  });
}
plain('TRANSPORT-C13', 'openai-compatible', x => { x.response.choices[0].finish_reason = 'content_filter'; x.expected.finishReason = 'content-filter'; });
for (const adapter of ['ollama', 'openai-compatible']) {
  const tag = adapter === 'ollama' ? 'O' : 'C';
  plain(`TRANSPORT-${tag}14`, adapter, x => {
    if (adapter === 'ollama') x.response.done_reason = ['stop']; else x.response.choices[0].finish_reason = ['stop'];
    x.expectedError = 'INVALID_PROVIDER_RESPONSE';
  });
  plain(`TRANSPORT-${tag}15`, adapter, x => {
    x.request.responseSchema = { ...schema, properties: { ...schema.properties, toJSON: { type: 'string' } } };
    if (adapter === 'ollama') { x.expectedBody.format = x.request.responseSchema; x.response.message.content = '{"summary":"公开摘要"}'; }
    else { x.expectedBody.response_format = { type: 'json_schema', json_schema: { name: 'output', strict: true, schema: x.request.responseSchema } }; x.response.choices[0].message.content = '{"summary":"公开摘要"}'; }
    x.response.toJSON = 'ordinary JSON data';
    x.expected.text = '{"summary":"公开摘要"}';
  });
  plain(`TRANSPORT-${tag}16`, adapter, x => {
    x.responseText = '\uFEFF' + JSON.stringify(x.response);
    x.expectedError = 'INVALID_PROVIDER_RESPONSE';
  });
  plain(`TRANSPORT-${tag}17`, adapter, x => {
    x.responseText = JSON.stringify(x.response)
      .replace('"prompt_eval_count":7', '"prompt_eval_count":7e0').replace('"eval_count":3', '"eval_count":3.0')
      .replace('"prompt_tokens":7', '"prompt_tokens":7e0').replace('"completion_tokens":3', '"completion_tokens":3.0');
  });
  plain(`TRANSPORT-${tag}18`, adapter, x => {
    const response = structuredClone(x.response);
    if (adapter === 'ollama') response.message.content = '\ud800'; else response.choices[0].message.content = '\ud800';
    x.responseText = JSON.stringify(response); x.expectedError = 'INVALID_PROVIDER_RESPONSE';
  });
  plain(`TRANSPORT-${tag}19`, adapter, x => {
    x.request.tools = [tool]; x.expectedBody.tools = [{ type: 'function', function: tool }];
    const response = structuredClone(x.response);
    const call = { name: tool.name, arguments: { query: '\ud800' } };
    if (adapter === 'ollama') response.message.tool_calls = [{ function: call }];
    else { response.choices[0].message.tool_calls = [{ id: 'call-1', type: 'function', function: { ...call, arguments: JSON.stringify(call.arguments) } }]; response.choices[0].finish_reason = 'tool_calls'; }
    x.responseText = JSON.stringify(response); x.expectedError = 'INVALID_PROVIDER_RESPONSE';
  });
  plain(`TRANSPORT-${tag}20`, adapter, x => {
    x.request.responseSchema = schema;
    const text = JSON.stringify({ summary: '\ud800' });
    if (adapter === 'ollama') { x.expectedBody.format = schema; x.response.message.content = text; }
    else { x.expectedBody.response_format = { type: 'json_schema', json_schema: { name: 'output', strict: true, schema } }; x.response.choices[0].message.content = text; }
    x.expectedError = 'INVALID_PROVIDER_RESPONSE';
  });
  plain(`TRANSPORT-${tag}21`, adapter, x => {
    const response = structuredClone(x.response);
    if (adapter === 'ollama') response.message.content = 'SCALAR_PAIR'; else response.choices[0].message.content = 'SCALAR_PAIR';
    x.responseText = JSON.stringify(response).replace('SCALAR_PAIR', '\\ud83d\\ude3a');
    x.expected.text = '😺';
  });
}
writeFileSync(new URL('../specifications/scenarios/ai-inference-transport.json', import.meta.url), `${JSON.stringify({ schemaVersion: 1, id: 'AI-INFERENCE-TRANSPORT', revision: 1, scope: 'Synthetic non-streaming transport component vectors; not product acceptance', cases }, null, 2)}\n`);
