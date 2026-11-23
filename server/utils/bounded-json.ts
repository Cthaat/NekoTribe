import type { H3Event } from 'h3';
import { v2BadRequest } from './v2';

export async function readBoundedJsonObject(event: H3Event, maxBytes: number, invalid: string): Promise<Record<string, unknown>> {
  const pieces: Buffer[] = [];
  let bytes = 0;
  for await (const chunk of event.node.req.iterator({ destroyOnReturn: false }) as AsyncIterable<Uint8Array>) {
    bytes += chunk.byteLength;
    if (bytes > maxBytes) v2BadRequest(invalid);
    pieces.push(Buffer.from(chunk));
  }
  let value: unknown;
  try { value = JSON.parse(Buffer.concat(pieces, bytes).toString('utf8')); }
  catch { return v2BadRequest(invalid); }
  if (!value || typeof value !== 'object' || Array.isArray(value)) return v2BadRequest(invalid);
  return value as Record<string, unknown>;
}
