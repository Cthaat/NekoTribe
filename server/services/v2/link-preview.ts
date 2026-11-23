import { createHash } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { request as httpRequest } from 'node:http';
import type { IncomingMessage, RequestOptions } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { BlockList, isIP } from 'node:net';
import { Parser } from 'htmlparser2';
import policy from '../../../specifications/requirements/link-preview.json';
import { observeCacheRead } from '../../utils/observability';
import { getRedisClient } from '../../utils/redis';
import { v2BadRequest } from '../../utils/v2';

interface LinkPreview {
  url: string;
  title: string;
  description: string;
  site_name: string;
}

interface ResolvedAddress {
  address: string;
  family: number;
}

interface PreviewCache {
  get(key: string): Promise<string | null>;
  set(key: string, value: string, mode: 'EX', ttl: number): Promise<unknown>;
}

type PreviewHop = { location: string } | { html: string } | null;

const denied = new BlockList();
for (const cidr of policy.blocked_cidrs) {
  const [ip, bits] = cidr.split('/') as [string, string];
  denied.addSubnet(ip, Number(bits), isIP(ip) === 4 ? 'ipv4' : 'ipv6');
}
const globalV6 = new BlockList();
const [v6Network, v6Bits] = policy.ipv6_public_prefix.split('/') as [string, string];
globalV6.addSubnet(v6Network, Number(v6Bits), 'ipv6');

const redirectStatuses = new Set([301, 302, 303, 307, 308]);

function hostname(url: URL): string {
  return url.hostname.replace(/^\[|\]$/g, '');
}

function isPublicAddress(address: string, family: number): boolean {
  if (isIP(address) !== family) return false;
  if (family === 4) return !denied.check(address, 'ipv4');
  return family === 6 && globalV6.check(address, 'ipv6') && !denied.check(address, 'ipv6');
}

function isPublicHostname(host: string): boolean {
  const name = host.replace(/\.$/, '');
  return name.length <= 253 &&
    name.split('.').every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label)) &&
    !policy.blocked_host_suffixes.some(suffix => name === suffix || name.endsWith(`.${suffix}`));
}

function validatedUrl(raw: unknown, base?: URL): URL {
  if (typeof raw !== 'string' || !raw || Buffer.byteLength(raw) > policy.max_url_bytes) return v2BadRequest();
  // URL parsing can silently normalize these characters before the destination is checked.
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u0020\u007f\\]/u.test(raw)) return v2BadRequest();
  const rawScheme = /^[a-z][a-z0-9+.-]*:/i.test(raw);
  const authority = /^(?:https?:)?\/\/([^/?#]*)/i.exec(raw)?.[1];
  if ((!base && !rawScheme) || ((rawScheme || raw.startsWith('//')) && !authority) ||
      (authority && (/[@%]/.test(authority) || authority.endsWith(':')))) {
    return v2BadRequest();
  }
  const url = URL.parse(raw, base);
  if (!url || !['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.port) {
    return v2BadRequest();
  }
  url.hash = '';
  if (Buffer.byteLength(url.href) > policy.max_url_bytes) return v2BadRequest();

  const host = hostname(url);
  const family = isIP(host);
  if ((!family && !isPublicHostname(host)) || (family && !isPublicAddress(host, family)) ||
      (family === 4 && authority && authority.split(':')[0] !== host)) return v2BadRequest();
  return url;
}

async function withDeadline<T>(promise: Promise<T>, signal: AbortSignal): Promise<T | null> {
  if (signal.aborted) {
    void promise.catch(() => {});
    return null;
  }
  let abort: () => void;
  const elapsed = new Promise<null>(resolve => {
    abort = () => resolve(null);
    signal.addEventListener('abort', abort, { once: true });
  });
  try {
    return await Promise.race([promise.catch(() => null), elapsed]);
  } finally {
    signal.removeEventListener('abort', abort!);
  }
}

function normalizeMetadata(value: string, limit: number): string {
  return Array.from(value.replace(/[\s\p{Cc}]+/gu, ' ').trim()).slice(0, limit).join('');
}

function parsePreview(url: URL, html: string): LinkPreview | null {
  const metadata = new Map<string, string>();
  const metadataKeys = new Set(['og:title', 'og:description', 'description', 'og:site_name']);
  let pageTitle = '';
  let inTitle = false;
  new Parser({
    onopentag(name, attributes) {
      if (name === 'title' && !pageTitle) inTitle = true;
      if (name !== 'meta') return;
      const key = (attributes.property || attributes.name || '').trim().toLowerCase();
      const value = attributes.content?.trim();
      if (metadataKeys.has(key) && value && !metadata.has(key)) metadata.set(key, value);
    },
    ontext(text) { if (inTitle) pageTitle += text; },
    onclosetag(name) { if (name === 'title') inTitle = false; },
  }).end(html);
  const title = metadata.get('og:title') || pageTitle;
  const site = hostname(url);
  const description = normalizeMetadata(metadata.get('og:description') || metadata.get('description') || '', policy.description_chars);
  if (!title.trim() && !description) return null;
  return {
    url: url.href,
    title: normalizeMetadata(title, policy.title_chars) || normalizeMetadata(site, policy.title_chars),
    description,
    site_name: normalizeMetadata(metadata.get('og:site_name') || site, policy.site_name_chars),
  };
}

async function readHop(response: IncomingMessage): Promise<PreviewHop> {
  try {
    const status = response.statusCode ?? 0;
    if (redirectStatuses.has(status) && response.headers.location) {
      return { location: response.headers.location };
    }
    const type = response.headers['content-type']?.split(';')[0]?.trim().toLowerCase();
    const encoding = response.headers['content-encoding']?.trim().toLowerCase();
    if (status < 200 || status > 299 || (type !== 'text/html' && type !== 'application/xhtml+xml') ||
        (encoding && encoding !== 'identity') || Number(response.headers['content-length']) > policy.max_body_bytes) {
      return null;
    }
    let bytes = 0;
    const chunks: Buffer[] = [];
    for await (const chunk of response as AsyncIterable<Buffer>) {
      bytes += chunk.length;
      if (bytes > policy.max_body_bytes) return null;
      chunks.push(chunk);
    }
    return { html: Buffer.concat(chunks, bytes).toString('utf8') };
  } finally {
    response.destroy();
  }
}

function requestHop(url: URL, target: ResolvedAddress, signal: AbortSignal): Promise<PreviewHop> {
  return new Promise((resolve, reject) => {
    const request = url.protocol === 'https:' ? httpsRequest : httpRequest;
    const options: RequestOptions & { autoSelectFamily: boolean } = {
      agent: false,
      autoSelectFamily: false,
      family: target.family,
      lookup: (_hostname, _options, callback) => callback(null, target.address, target.family),
      signal,
      headers: { Accept: 'text/html, application/xhtml+xml', 'Accept-Encoding': 'identity' },
    };
    const outgoing = request(url, options, response => { void readHop(response).then(resolve, reject); });
    outgoing.once('error', reject);
    outgoing.end();
  });
}

export function createLinkPreviewService({
  resolve = (host: string) => lookup(host, { all: true }),
  fetchHop = requestHop,
  cache = () => {
    const redis = getRedisClient();
    return redis?.status === 'ready' ? redis : null;
  },
}: {
  resolve?: (host: string) => Promise<ResolvedAddress[]>;
  fetchHop?: typeof requestHop;
  cache?: () => PreviewCache | null;
} = {}) {
  return async function previewLink(raw: unknown): Promise<LinkPreview | null> {
    let url = validatedUrl(raw);
    const key = policy.cache_prefix + createHash('sha256').update(url.href).digest('hex');
    const cached = cache();
    if (cached) {
      const read = await withDeadline(cached.get(key).then(raw => ({ raw })), AbortSignal.timeout(policy.cache_timeout_ms));
      if (read?.raw) {
        try {
          const entry = JSON.parse(read.raw) as LinkPreview | null;
          if (entry && typeof entry.title === 'string' && typeof entry.description === 'string' &&
              typeof entry.site_name === 'string' && validatedUrl(entry.url).href === entry.url) {
            observeCacheRead('hit');
            return entry;
          }
        } catch { /* Replace an invalid entry on success. */ }
      }
      observeCacheRead(read ? 'miss' : 'degraded');
    } else observeCacheRead('degraded');

    const signal = AbortSignal.timeout(policy.timeout_ms);
    for (let hop = 0; hop <= policy.max_redirects && !signal.aborted; hop++) {
      const host = hostname(url);
      const literal = isIP(host);
      const addresses = literal ? [{ address: host, family: literal }]
        : await withDeadline(resolve(host), signal);
      if (!addresses?.length || signal.aborted) return null;
      if (addresses.some(({ address, family }) => !isPublicAddress(address, family))) return v2BadRequest();
      const target = addresses[0]!;
      const result = await withDeadline(fetchHop(url, target, signal), signal);
      if (!result || signal.aborted) return null;
      if ('location' in result) {
        url = validatedUrl(result.location, url);
        continue;
      }
      const preview = parsePreview(url, result.html);
      if (preview && cached) {
        await withDeadline(cached.set(key, JSON.stringify(preview), 'EX', policy.cache_ttl_seconds),
          AbortSignal.timeout(policy.cache_timeout_ms));
      }
      return preview;
    }
    return null;
  };
}

export const previewLink = createLinkPreviewService();
