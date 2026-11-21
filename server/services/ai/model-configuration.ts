export type AiRole = 'knowledge' | 'writing' | 'agent' | 'moderation';
export type AiCapability = 'tools' | 'structured-output' | 'vision';
export type AiAdapter = 'openai-compatible' | 'ollama';
export const MAX_STORED_MODEL_REVISION = 999999999999999;
export type AiConfigurationErrorCode = 'INVALID_CONFIGURATION' | 'UNKNOWN_ROLE' |
  'UNSUPPORTED_CAPABILITY' | 'STALE_CONFIGURATION' | 'REVISION_REUSED';

export class AiConfigurationError extends Error {
  readonly code: AiConfigurationErrorCode;
  constructor(code: AiConfigurationErrorCode) {
    super({
      INVALID_CONFIGURATION: 'AI model configuration is invalid',
      UNKNOWN_ROLE: 'AI model role is unknown',
      UNSUPPORTED_CAPABILITY: 'AI model capability is unsupported',
      STALE_CONFIGURATION: 'AI model configuration has changed',
      REVISION_REUSED: 'AI model configuration requires a newer revision'
    }[code]);
    this.name = 'AiConfigurationError';
    this.code = code;
  }
}

interface Provider {
  readonly id: string;
  readonly adapter: AiAdapter;
  readonly baseUrl: string;
  readonly apiKeyEnv: string | null;
}
interface Model {
  readonly id: string;
  readonly providerId: string;
  readonly model: string;
  readonly modelVersion?: string;
  readonly capabilities: readonly AiCapability[];
  readonly contextWindowTokens: number;
  readonly maxOutputTokens: number;
}
interface Configuration {
  readonly revision: number;
  readonly providers: readonly Provider[];
  readonly models: readonly Model[];
  readonly bindings: Readonly<Record<AiRole, string>>;
}
export interface AiModelSelection {
  readonly configurationRevision: number;
  readonly role: AiRole;
  readonly profileId: string;
  readonly providerId: string;
  readonly adapter: AiAdapter;
  readonly baseUrl: string;
  readonly model: string;
  readonly modelVersion?: string;
  readonly apiKeyEnv: string | null;
  readonly capabilities: readonly AiCapability[];
  readonly contextWindowTokens: number;
  readonly maxOutputTokens: number;
}

const roles: readonly AiRole[] = ['knowledge', 'writing', 'agent', 'moderation'];
const identifier = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
export function validAiModelVersion(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/.test(value) && !/\s/.test(value);
}
function fail(code: AiConfigurationErrorCode = 'INVALID_CONFIGURATION'): never { throw new AiConfigurationError(code); }
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail();
  return value as Record<string, unknown>;
}
function keys(value: Record<string, unknown>, required: readonly string[], optional: readonly string[] = []): void {
  if (required.some(key => !Object.hasOwn(value, key)) ||
    Object.keys(value).some(key => !required.includes(key) && !optional.includes(key))) fail();
}
function array(value: unknown): unknown[] { if (!Array.isArray(value) || !value.length) fail(); return Array.from(value); }
function text(value: unknown): string {
  if (typeof value !== 'string' || !value || /^[\p{White_Space}\uFEFF]|[\p{White_Space}\uFEFF]$/u.test(value)) fail();
  return value;
}
function id(value: unknown): string { const result = text(value); if (!identifier.test(result)) fail(); return result; }
function integer(value: unknown, maximum = Number.MAX_SAFE_INTEGER): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value <= 0 || value > maximum) fail();
  return value;
}
function capability(value: unknown, code: AiConfigurationErrorCode = 'INVALID_CONFIGURATION'): AiCapability {
  if (value !== 'tools' && value !== 'structured-output' && value !== 'vision') fail(code);
  return value;
}
function capabilities(value: unknown, code: AiConfigurationErrorCode = 'INVALID_CONFIGURATION'): readonly AiCapability[] {
  if (!Array.isArray(value)) fail(code);
  const result = Array.from(value, (item: unknown) => capability(item, code));
  if (new Set(result).size !== result.length) fail(code);
  return Object.freeze(result.sort());
}
export function normalizeAiHttpBaseUrl(value: unknown): string {
  const result = text(value);
  if (!/^https?:\/\//.test(result) || /[\p{White_Space}\uFEFF\u0000-\u0020\u007f]/u.test(result) ||
    result.includes('?') || result.includes('#') || result.includes('\\')) fail();
  const authority = result.slice(result.indexOf('://') + 3).split('/')[0];
  const parts = /^(\[[0-9a-fA-F:.]+\]|[A-Za-z0-9._-]+)(?::([0-9]+))?$/.exec(authority ?? '');
  if (!parts) fail();
  const host = parts[1];
  if (!host) fail();
  if (parts[2] !== undefined && (Number(parts[2]) < 1 || Number(parts[2]) > 65535)) fail();
  if (!host.startsWith('[')) {
    const dns = host.endsWith('.') ? host.slice(0, -1) : host;
    const labels = dns.split('.');
    if (host.length > 253 || labels.some(label => !/^[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?$/.test(label))) fail();
    const last = labels[labels.length - 1] ?? '';
    if (/^(?:\d+|0x[0-9a-f]+)$/i.test(last)) {
      if (host.endsWith('.') || labels.length !== 4 || labels.some(label =>
        !/^(?:0|[1-9]\d{0,2})$/.test(label) || Number(label) > 255)) fail();
    }
  }
  try {
    const parsed = new URL(result);
    if (!parsed.hostname || parsed.username || parsed.password) fail();
  } catch { fail(); }
  return result.replace(/\/+$/, '');
}
function provider(value: unknown): Provider {
  const entry = record(value);
  keys(entry, ['id', 'adapter', 'baseUrl'], ['apiKeyEnv']);
  if (entry.adapter !== 'openai-compatible' && entry.adapter !== 'ollama') fail();
  let reference: string | null = null;
  if (entry.apiKeyEnv !== undefined && entry.apiKeyEnv !== null && entry.apiKeyEnv !== '') {
    reference = text(entry.apiKeyEnv);
    if (!/^[A-Z_][A-Z0-9_]*$/.test(reference)) fail();
  }
  return Object.freeze({ id: id(entry.id), adapter: entry.adapter, baseUrl: normalizeAiHttpBaseUrl(entry.baseUrl), apiKeyEnv: reference });
}
function model(value: unknown): Model {
  const entry = record(value);
  keys(entry, ['id', 'providerId', 'model', 'capabilities', 'contextWindowTokens', 'maxOutputTokens'], ['modelVersion']);
  const name = text(entry.model);
  if ([...name].length > 256) fail();
  const version = entry.modelVersion;
  if (version !== null && version !== undefined && !validAiModelVersion(version)) fail();
  const context = integer(entry.contextWindowTokens, 2147483647);
  const output = integer(entry.maxOutputTokens, 2147483647);
  if (output >= context) fail();
  return Object.freeze({ id: id(entry.id), providerId: id(entry.providerId), model: name,
    ...(version != null ? { modelVersion: version } : {}),
    capabilities: capabilities(entry.capabilities), contextWindowTokens: context, maxOutputTokens: output });
}
function parse(value: unknown): Configuration {
  const entry = record(value);
  keys(entry, ['schemaVersion', 'revision', 'providers', 'models', 'bindings']);
  if (entry.schemaVersion !== 1) fail();
  const revision = integer(entry.revision);
  if (revision > MAX_STORED_MODEL_REVISION) fail('INVALID_CONFIGURATION');
  const providers = array(entry.providers).map(provider);
  const models = array(entry.models).map(model);
  if (new Set(providers.map(item => item.id)).size !== providers.length ||
    new Set(models.map(item => item.id)).size !== models.length) fail();
  if (models.some(item => !providers.some(provider => provider.id === item.providerId))) fail();
  const rawBindings = record(entry.bindings);
  keys(rawBindings, roles);
  const bindings = Object.freeze({ knowledge: id(rawBindings.knowledge), writing: id(rawBindings.writing),
    agent: id(rawBindings.agent), moderation: id(rawBindings.moderation) });
  for (const role of roles) {
    const selected = models.find(item => item.id === bindings[role]);
    if (!selected || (role === 'agent' && !selected.capabilities.includes('tools')) ||
      (role === 'moderation' && !selected.capabilities.includes('structured-output'))) fail();
  }
  return Object.freeze({ revision, providers: Object.freeze(providers), models: Object.freeze(models), bindings });
}

// Server-internal configuration only: this component never reads credentials,
// invokes a provider, or approves a URL for network access.
export class AiModelRouter {
  #configuration: Configuration;
  constructor(configuration: unknown) { this.#configuration = parse(configuration); }

  select(role: string, requiredCapabilities: readonly string[] = []): AiModelSelection {
    if (!roles.includes(role as AiRole)) fail('UNKNOWN_ROLE');
    const selectedRole = role as AiRole;
    const required = capabilities(requiredCapabilities, 'UNSUPPORTED_CAPABILITY');
    const configuration = this.#configuration;
    const selected = configuration.models.find(item => item.id === configuration.bindings[selectedRole]);
    if (!selected) fail();
    if (required.some(item => !selected.capabilities.includes(item))) fail('UNSUPPORTED_CAPABILITY');
    const target = configuration.providers.find(item => item.id === selected.providerId);
    if (!target) fail();
    return Object.freeze({ configurationRevision: configuration.revision, role: selectedRole,
      profileId: selected.id, providerId: target.id, adapter: target.adapter, baseUrl: target.baseUrl,
      model: selected.model, apiKeyEnv: target.apiKeyEnv, capabilities: Object.freeze([...selected.capabilities]),
      ...(selected.modelVersion !== undefined ? { modelVersion: selected.modelVersion } : {}),
      contextWindowTokens: selected.contextWindowTokens, maxOutputTokens: selected.maxOutputTokens });
  }

  replace(configuration: unknown, expectedRevision: number): void {
    if (expectedRevision !== this.#configuration.revision) fail('STALE_CONFIGURATION');
    const next = parse(configuration);
    if (next.revision <= this.#configuration.revision) fail('REVISION_REUSED');
    this.#configuration = next;
  }
}
