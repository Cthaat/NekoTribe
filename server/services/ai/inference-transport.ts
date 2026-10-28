import type { AiModelSelection } from './model-configuration.ts';

export type AiTransportErrorCode = 'INVALID_REQUEST' | 'UNSUPPORTED_CAPABILITY' | 'MISSING_CREDENTIAL' |
  'PROVIDER_UNAVAILABLE' | 'PROVIDER_REJECTED' | 'INVALID_PROVIDER_RESPONSE' | 'RESPONSE_TOO_LARGE' | 'TIMEOUT' | 'CANCELLED';
export class AiTransportError extends Error {
  readonly code: AiTransportErrorCode;
  constructor(code: AiTransportErrorCode) { super(code); this.name = 'AiTransportError'; this.code = code; }
}
type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type ObjectValue = { [key: string]: Json };
export interface AiInferenceResult {
  text: string;
  toolCalls: { id: string; name: string; arguments: ObjectValue }[];
  finishReason: 'stop' | 'length' | 'tool-calls' | 'content-filter';
  usage: { inputTokens: number | null; outputTokens: number | null };
}
const LIMIT = 1048576;
function scalarString(value: string): boolean {
  for (let index = 0; index < value.length; index++) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const low = value.charCodeAt(++index);
      if (!(low >= 0xdc00 && low <= 0xdfff)) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) return false;
  }
  return true;
}
function fail(code: AiTransportErrorCode = 'INVALID_PROVIDER_RESPONSE'): never { throw new AiTransportError(code); }
function object(value: Json | undefined, code: AiTransportErrorCode = 'INVALID_PROVIDER_RESPONSE'): ObjectValue {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) fail(code);
  return value;
}
// Check before cloning: bounded traversal rejects getters, custom serialization,
// exotic objects, holes, cycles and non-JSON values.
function jsonCopy(value: unknown, depth: number, code: AiTransportErrorCode): Json {
  const seen = new Set<object>();
  const stack: { value: unknown; depth: number; leave?: boolean }[] = [{ value, depth: 0 }];
  while (stack.length) {
    const item = stack.pop();
    if (!item) break;
    const current = item.value;
    if (typeof current === 'string') { if (!scalarString(current)) fail(code); continue; }
    if (current === null || typeof current === 'boolean') continue;
    if (typeof current === 'number' && Number.isFinite(current)) continue;
    if (typeof current !== 'object') fail(code);
    if (item.leave) { seen.delete(current); continue; }
    if (item.depth >= depth || seen.has(current)) fail(code);
    const array = Array.isArray(current);
    if (array ? Object.getPrototypeOf(current) !== Array.prototype : Object.getPrototypeOf(current) !== Object.prototype && Object.getPrototypeOf(current) !== null) fail(code);
    const names = Reflect.ownKeys(current);
    if (names.some(name => typeof name !== 'string' || !scalarString(name))) fail(code);
    if (array && (names.length !== current.length + 1 || names.some(name => name !== 'length' &&
      (!/^(0|[1-9]\d*)$/.test(String(name)) || Number(name) >= current.length || Number(name) >= 4294967295)))) fail(code);
    seen.add(current); stack.push({ value: current, depth: item.depth, leave: true });
    for (const name of names) {
      if (array && name === 'length') continue;
      const descriptor = Object.getOwnPropertyDescriptor(current, name);
      if (!descriptor || !('value' in descriptor) || !descriptor.enumerable) fail(code);
      stack.push({ value: descriptor.value, depth: item.depth + 1 });
    }
  }
  return JSON.parse(JSON.stringify(value)) as Json;
}
function exact(value: ObjectValue, required: string[], optional: string[] = []): void {
  if (required.some(key => !Object.hasOwn(value, key)) || Object.keys(value).some(key => !required.includes(key) && !optional.includes(key))) fail('INVALID_REQUEST');
}
function parsed(text: string, depth = 70): Json {
  try { return jsonCopy(JSON.parse(text), depth, 'INVALID_PROVIDER_RESPONSE'); } catch { return fail(); }
}
function encodeMessages(selection: AiModelSelection, messages: Json[]): { encoded: Json[]; hasHistory: boolean } {
  const encoded: Json[] = [];
  let pending: { id: string; name: string }[] = [];
  let cursor = 0;
  let hasHistory = false;
  for (const raw of messages) {
    const message = object(raw, 'INVALID_REQUEST');
    if (typeof message.role !== 'string' || typeof message.content !== 'string') fail('INVALID_REQUEST');
    if (message.role === 'tool') {
      exact(message, ['role', 'content', 'toolCallId']);
      const call = pending[cursor];
      if (!call || message.toolCallId !== call.id) fail('INVALID_REQUEST');
      encoded.push(selection.adapter === 'ollama'
        ? { role: 'tool', tool_name: call.name, content: message.content }
        : { role: 'tool', tool_call_id: call.id, content: message.content });
      cursor++;
      if (cursor === pending.length) { pending = []; cursor = 0; }
      continue;
    }
    if (pending.length || !['system', 'user', 'assistant'].includes(message.role)) fail('INVALID_REQUEST');
    if (message.role !== 'assistant' || !Object.hasOwn(message, 'toolCalls')) {
      exact(message, ['role', 'content']);
      encoded.push(message);
      continue;
    }
    exact(message, ['role', 'content', 'toolCalls']);
    if (!Array.isArray(message.toolCalls) || message.toolCalls.length < 1 || message.toolCalls.length > 32) fail('INVALID_REQUEST');
    const ids = new Set<string>();
    const providerCalls = message.toolCalls.map((rawCall, index): Json => {
      const call = object(rawCall, 'INVALID_REQUEST');
      exact(call, ['id', 'name', 'arguments']);
      if (typeof call.id !== 'string' || !call.id || [...call.id].length > 128 || ids.has(call.id) ||
          typeof call.name !== 'string' || !/^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(call.name)) fail('INVALID_REQUEST');
      const args = object(call.arguments, 'INVALID_REQUEST');
      ids.add(call.id); pending.push({ id: call.id, name: call.name });
      if (selection.adapter === 'ollama') {
        return { type: 'function', function: { index, name: call.name, arguments: args } };
      }
      return { id: call.id, type: 'function', function: { name: call.name, arguments: JSON.stringify(args) } };
    });
    hasHistory = true;
    encoded.push({ role: 'assistant', content: message.content, tool_calls: providerCalls });
  }
  if (pending.length) fail('INVALID_REQUEST');
  return { encoded, hasHistory };
}
function requestBody(selection: AiModelSelection, input: unknown): { body: ObjectValue; tools: Set<string>; structured: boolean } {
  const request = object(jsonCopy(input, 64, 'INVALID_REQUEST'), 'INVALID_REQUEST');
  exact(request, ['messages'], ['tools', 'responseSchema']);
  if (!Array.isArray(request.messages) || request.messages.length < 1 || request.messages.length > 128) fail('INVALID_REQUEST');
  const { encoded: messages, hasHistory } = encodeMessages(selection, request.messages);
  const tools = Object.hasOwn(request, 'tools') ? request.tools : [];
  if (!Array.isArray(tools) || tools.length > 32) fail('INVALID_REQUEST');
  const names = new Set<string>();
  for (const raw of tools) {
    const tool = object(raw, 'INVALID_REQUEST'); exact(tool, ['name', 'description', 'parameters']);
    if (typeof tool.name !== 'string' || !/^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(tool.name) || names.has(tool.name) || typeof tool.description !== 'string') fail('INVALID_REQUEST');
    if (object(tool.parameters, 'INVALID_REQUEST').type !== 'object') fail('INVALID_REQUEST');
    names.add(tool.name);
  }
  const structured = Object.hasOwn(request, 'responseSchema');
  if (structured && (object(request.responseSchema, 'INVALID_REQUEST').type !== 'object' || tools.length)) fail('INVALID_REQUEST');
  if (((tools.length || hasHistory) && !selection.capabilities.includes('tools')) || (structured && !selection.capabilities.includes('structured-output'))) fail('UNSUPPORTED_CAPABILITY');
  const body: ObjectValue = { model: selection.model, messages, stream: false };
  if (selection.adapter === 'openai-compatible') { body.n = 1; body.max_tokens = selection.maxOutputTokens; }
  else if (selection.adapter === 'ollama') body.options = { num_predict: selection.maxOutputTokens, num_ctx: selection.contextWindowTokens };
  else fail('INVALID_REQUEST');
  if (tools.length) body.tools = tools.map(tool => ({ type: 'function', function: tool }));
  if (structured) {
    const schema = request.responseSchema;
    if (schema === undefined) fail('INVALID_REQUEST');
    if (selection.adapter === 'ollama') body.format = schema;
    else body.response_format = { type: 'json_schema', json_schema: { name: 'output', strict: true, schema } };
  }
  jsonCopy(body, 70, 'INVALID_REQUEST');
  return { body, tools: names, structured };
}
function tokens(value: Json | undefined): number | null {
  if (value === undefined) return null;
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) fail();
  return value;
}
function normalize(selection: AiModelSelection, raw: Json, names: Set<string>, structured: boolean): AiInferenceResult {
  const response = object(raw);
  let message: ObjectValue;
  let finish: AiInferenceResult['finishReason'];
  let inputTokens: number | null; let outputTokens: number | null;
  const openai = selection.adapter === 'openai-compatible';
  if (openai) {
    if (!Array.isArray(response.choices) || response.choices.length !== 1) fail();
    const choice = object(response.choices[0]);
    if (choice.index !== 0 || typeof choice.finish_reason !== 'string' || !['stop', 'length', 'tool_calls', 'content_filter'].includes(choice.finish_reason)) fail();
    const reasons: Record<string, AiInferenceResult['finishReason']> = { stop: 'stop', length: 'length', tool_calls: 'tool-calls', content_filter: 'content-filter' };
    const reason = reasons[String(choice.finish_reason)];
    if (!reason) fail();
    finish = reason;
    message = object(choice.message);
    const usage = response.usage === undefined || response.usage === null ? {} : object(response.usage);
    inputTokens = tokens(usage.prompt_tokens); outputTokens = tokens(usage.completion_tokens);
  } else {
    if (response.done !== true || typeof response.done_reason !== 'string' || !['stop', 'length'].includes(response.done_reason)) fail();
    finish = response.done_reason as 'stop' | 'length'; message = object(response.message);
    inputTokens = tokens(response.prompt_eval_count); outputTokens = tokens(response.eval_count);
  }
  if (message.role !== 'assistant') fail();
  const calls = message.tool_calls === undefined || message.tool_calls === null ? [] : message.tool_calls;
  if (!Array.isArray(calls) || calls.length > 32) fail();
  const ids = new Set<string>();
  const toolCalls = calls.map((raw, index) => {
    const call = object(raw); const fn = object(call.function);
    if ((openai || Object.hasOwn(call, 'type')) && call.type !== 'function') fail();
    if (typeof fn.name !== 'string' || !names.has(fn.name)) fail();
    const id = openai ? call.id : `ollama-${index}`;
    if (typeof id !== 'string' || !id || [...id].length > 128 || ids.has(id)) fail();
    ids.add(id);
    if (openai && typeof fn.arguments !== 'string') fail();
    const args = openai ? parsed(fn.arguments as string, 64) : jsonCopy(fn.arguments, 64, 'INVALID_PROVIDER_RESPONSE');
    return { id, name: fn.name, arguments: object(args) };
  });
  if (toolCalls.length) {
    if (openai ? finish !== 'tool-calls' : finish !== 'stop') fail();
    finish = 'tool-calls';
  }
  if (message.content !== null && typeof message.content !== 'string') fail();
  if (!openai && typeof message.content !== 'string') fail();
  if (!toolCalls.length && (typeof message.content !== 'string' || message.content.length === 0 || finish === 'tool-calls')) fail();
  const text = typeof message.content === 'string' ? message.content : '';
  if (structured) { if (finish !== 'stop') fail(); object(parsed(text, 64)); }
  return { text, toolCalls, finishReason: finish, usage: { inputTokens, outputTokens } };
}

// Server-internal, non-streaming adapter. Tool calls remain logical proposals.
export class AiInferenceTransport {
  readonly #resolver: (reference: string) => string | undefined;
  readonly #timeoutMs: number;
  constructor(resolver: (reference: string) => string | undefined = () => undefined, timeoutMs = 30000) {
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 300000) fail('INVALID_REQUEST');
    this.#resolver = resolver; this.#timeoutMs = timeoutMs;
  }
  async infer(snapshot: AiModelSelection, input: unknown, signal?: AbortSignal): Promise<AiInferenceResult> {
    if (signal?.aborted) fail('CANCELLED');
    const selection = { ...snapshot, capabilities: [...snapshot.capabilities] };
    let prepared: ReturnType<typeof requestBody>;
    try { prepared = requestBody(selection, input); }
    catch (error) { if (error instanceof AiTransportError) throw error; return fail('INVALID_REQUEST'); }
    const { body, tools, structured } = prepared;
    const encoded = JSON.stringify(body);
    if (new TextEncoder().encode(encoded).length > LIMIT) fail('INVALID_REQUEST');
    const headers: Record<string, string> = { 'Content-Type': 'application/json', 'Accept-Encoding': 'identity' };
    if (selection.apiKeyEnv !== null) {
      let credential: string | undefined;
      try { credential = this.#resolver(selection.apiKeyEnv); } catch { fail('MISSING_CREDENTIAL'); }
      if (typeof credential !== 'string' || !/^[\x21-\x7e]+$/.test(credential)) fail('MISSING_CREDENTIAL');
      headers.Authorization = `Bearer ${credential}`;
    }
    let url: URL;
    try {
      url = new URL(selection.baseUrl.replace(/\/+$/, '') + (selection.adapter === 'ollama' ? '/api/chat' : '/chat/completions'));
      if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) fail('INVALID_REQUEST');
    } catch { return fail('INVALID_REQUEST'); }
    const controller = new AbortController(); let timedOut = false;
    const cancel = () => controller.abort();
    signal?.addEventListener('abort', cancel, { once: true });
    if (signal?.aborted) controller.abort();
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, this.#timeoutMs);
    try {
      const response = await fetch(url, { method: 'POST', headers, body: encoded, redirect: 'manual', signal: controller.signal });
      if (!response.ok) { await response.body?.cancel(); fail('PROVIDER_REJECTED'); }
      const encoding = response.headers.get('content-encoding');
      if (encoding !== null && encoding.replace(/^[\t\n\v\f\r ]+|[\t\n\v\f\r ]+$/g, '').toLowerCase() !== 'identity') {
        await response.body?.cancel(); fail();
      }
      const chunks: Uint8Array[] = []; let size = 0;
      const reader = response.body?.getReader();
      if (!reader) fail();
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        size += chunk.value.byteLength;
        if (size > LIMIT) { await reader.cancel(); fail('RESPONSE_TOO_LARGE'); }
        chunks.push(chunk.value);
      }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      let text: string;
      try { text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes); } catch { return fail(); }
      return normalize(selection, parsed(text), tools, structured);
    } catch (error) {
      if (signal?.aborted) return fail('CANCELLED');
      if (timedOut) return fail('TIMEOUT');
      if (error instanceof AiTransportError) throw error;
      return fail('PROVIDER_UNAVAILABLE');
    } finally { clearTimeout(timer); signal?.removeEventListener('abort', cancel); }
  }
}
