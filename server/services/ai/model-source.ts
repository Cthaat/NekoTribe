import { open, stat } from 'node:fs/promises';
import { AiConfigurationError, AiModelRouter } from './model-configuration.ts';

const MAX_BYTES = 65536;
export { MAX_STORED_MODEL_REVISION } from './model-configuration.ts';

function parseModelConfigText(raw: string): AiModelRouter {
  const config: unknown = JSON.parse(raw);
  // Scan strings after syntax validation. Decoding each name also catches
  // duplicate names written with a different JSON escape.
  const objects: (Set<string> | null)[] = [];
  for (const match of raw.matchAll(/"(?:[^"\\]|\\.)*"|[{}\[\]]/gs)) {
    const [token] = match;
    if (token === '{') objects.push(new Set());
    else if (token === '[') objects.push(null);
    else if (token === '}' || token === ']') objects.pop();
    else {
      const value = JSON.parse(token) as string;
      if (!value.isWellFormed()) throw new AiConfigurationError('INVALID_CONFIGURATION');
      const object = objects.at(-1);
      if (!object) continue;
      let next = match.index! + token.length;
      while (/[ \t\r\n]/.test(raw[next] ?? '')) next++;
      if (raw[next] !== ':') continue;
      if (object.has(value)) throw new AiConfigurationError('INVALID_CONFIGURATION');
      object.add(value);
    }
  }
  return new AiModelRouter(config);
}

export function parseModelConfigBytes(bytes: Buffer) {
  if (bytes.length > MAX_BYTES) throw new AiConfigurationError('INVALID_CONFIGURATION');
  try {
    const raw = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
    const router = parseModelConfigText(raw);
    const revision = router.select('knowledge').configurationRevision;
    return { bytes, router, revision };
  } catch {
    // The caller receives a stable error without configuration contents.
  }
  throw new AiConfigurationError('INVALID_CONFIGURATION');
}

export async function readModelConfigFile(path: string) {
  if (!(await stat(path)).isFile()) throw new AiConfigurationError('INVALID_CONFIGURATION');
  const file = await open(path, 'r');
  const buffer = Buffer.alloc(MAX_BYTES + 1);
  let offset = 0;
  try {
    while (offset < buffer.length) {
      const { bytesRead } = await file.read(buffer, offset, buffer.length - offset, offset);
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
  } finally {
    await file.close();
  }
  return parseModelConfigBytes(buffer.subarray(0, offset));
}

class ModelFile {
  readonly path: string;
  private nextCheck = 0;
  private active?: AiModelRouter;
  private revision = 0;
  private pending?: Promise<void>;

  constructor(path: string) {
    this.path = path;
  }

  async load(): Promise<AiModelRouter> {
    const now = performance.now();
    if (!this.pending && now >= this.nextCheck) {
      this.nextCheck = now + 1000;
      this.pending = this.reload().finally(() => { this.pending = undefined; });
    }
    await this.pending;
    if (!this.active) throw new AiConfigurationError('INVALID_CONFIGURATION');
    return this.active;
  }

  private async reload(): Promise<void> {
    try {
      const { router, revision } = await readModelConfigFile(this.path);
      if (revision > this.revision) {
        this.active = router;
        this.revision = revision;
      }
    } catch {
      // A failed read or validation preserves the last complete revision.
    }
  }
}

let fileSource: ModelFile | undefined;

export async function configuredModelRouter(configuration?: string): Promise<AiModelRouter> {
  const path = process.env.AI_MODEL_CONFIG_FILE;
  if (configuration === undefined && path) {
    if (fileSource?.path !== path) fileSource = new ModelFile(path);
    return fileSource.load();
  }
  const raw = configuration ?? process.env.AI_MODEL_CONFIG_JSON;
  if (!raw || Buffer.byteLength(raw, 'utf8') > MAX_BYTES) throw new AiConfigurationError('INVALID_CONFIGURATION');
  try {
    return parseModelConfigText(raw);
  } catch {
    throw new AiConfigurationError('INVALID_CONFIGURATION');
  }
}
