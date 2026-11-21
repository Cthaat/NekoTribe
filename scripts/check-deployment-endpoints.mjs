import { createHash, randomBytes } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const timeoutMs = 5000;
const corsHeaders = [
  'authorization', 'content-type', 'x-request-id', 'x-client-platform',
  'x-device-fingerprint', 'x-device-info',
];

function parseBase(value, protocols) {
  const base = new URL(value);
  if (!protocols.includes(base.protocol) || base.username || base.password || /[?#]/.test(value)) {
    throw new Error('Expected an endpoint base URL without credentials, query or fragment.');
  }
  return base;
}

function route(base, path) {
  const target = new URL(base);
  target.pathname = `${base.pathname.replace(/\/+$/, '')}${path}`;
  return target;
}

function failed(status, reason) {
  return {ok:false, status, reason};
}

function unexpectedStatus(status) {
  if (status >= 300 && status < 400) return failed(status,'redirect');
  if (status === 404) return failed(status,'route-not-found');
  return failed(status,'unexpected-http-status');
}

async function apiStatus(url) {
  const response = await fetch(url, {
    headers: {accept:'application/json'}, redirect:'manual', signal:AbortSignal.timeout(timeoutMs),
  });
  const {status} = response;
  if (status !== 200 && status !== 503) {
    await response.body?.cancel();
    return unexpectedStatus(status);
  }
  let size = 0;
  const chunks = [];
  for await (const chunk of response.body ?? []) {
    size += chunk.length;
    if (size > 4096) return failed(status,'invalid-readiness-response');
    chunks.push(chunk);
  }
  try {
    const readiness = JSON.parse(Buffer.concat(chunks).toString('utf8'))?.status;
    if (status === 200 && readiness === 'ready') return {ok:true, status};
    if (status === 503 && readiness === 'unavailable') return failed(status,'backend-not-ready');
  } catch {}
  return failed(status,'invalid-readiness-response');
}

async function mediaStatus(url, origin) {
  const response = await fetch(url, {
    method:'HEAD', headers:origin ? {origin} : undefined, redirect:'manual', signal:AbortSignal.timeout(timeoutMs),
  });
  const {status} = response;
  if (status !== 200) return unexpectedStatus(status);
  const length = Number(response.headers.get('content-length'));
  const mime = response.headers.get('content-type')?.split(';',1)[0]?.trim().toLowerCase();
  const corsAllowed = !origin || origin === url.origin || response.headers.get('access-control-allow-origin') === origin;
  if (mime !== 'image/png' || !Number.isSafeInteger(length) || length <= 0) {
    return failed(status,'invalid-media-response');
  }
  return corsAllowed ? {ok:true, status} : failed(status,'media-cors-rejected');
}

async function apiCors(url, origin) {
  const response = await fetch(url, {
    method:'OPTIONS', redirect:'manual', signal:AbortSignal.timeout(timeoutMs),
    headers:{origin, 'access-control-request-method':'GET', 'access-control-request-headers':corsHeaders.join(',')},
  });
  await response.body?.cancel();
  const {status} = response;
  if (![200,204].includes(status)) return unexpectedStatus(status);
  const includes = (key, value) => response.headers.get(key)?.toLowerCase().split(',').some(item => item.trim() === value);
  const allowed = response.headers.get('access-control-allow-origin') === origin &&
    response.headers.get('access-control-allow-credentials') === 'true' && includes('access-control-allow-methods','get') &&
    corsHeaders.every(value => includes('access-control-allow-headers',value));
  return allowed ? {ok:true, status} : failed(status,'api-cors-rejected');
}

function realtimeStatus(url, origin) {
  const key = randomBytes(16).toString('base64');
  const accept = createHash('sha1').update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
  const request = url.protocol === 'https:' ? httpsRequest : httpRequest;
  return new Promise((resolve,reject) => {
    const probe = request(url, {
      signal:AbortSignal.timeout(timeoutMs),
      headers:{connection:'Upgrade', upgrade:'websocket', 'sec-websocket-key':key, 'sec-websocket-version':'13', ...(origin ? {origin} : {})},
    });
    probe.on('error',reject);
    probe.on('upgrade',(response,socket) => {
      socket.destroy();
      const status = response.statusCode;
      resolve(response.headers['sec-websocket-accept'] === accept
        ? {ok:true, status}
        : failed(status,'invalid-realtime-response'));
    });
    probe.on('response',response => {
      const status = response.statusCode;
      if (status !== 401) {
        response.destroy();
        resolve(status === 200 ? failed(status,'invalid-realtime-response') : unexpectedStatus(status));
        return;
      }
      // Native implementations may reject missing credentials before upgrading.
      // Check the application error envelope rather than accepting a proxy's 401.
      const chunks = [];
      let size = 0;
      response.on('error',reject);
      response.on('data',chunk => {
        size += chunk.length;
        if (size > 4096) {
          resolve(failed(status,'invalid-realtime-response'));
          response.destroy();
        } else chunks.push(chunk);
      });
      response.on('end',() => {
        let code;
        try {
          const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
          code = body?.code ?? body?.data?.code;
        } catch {}
        resolve(code === 40101 ? {ok:true, status} : failed(status,'invalid-realtime-response'));
      });
    });
    probe.end();
  });
}

export async function checkDeploymentEndpoints({api, media, realtime, origin}) {
  const http = ['http:','https:'];
  const apiBase = parseBase(api,http);
  const mediaBase = media ? parseBase(media,http) : apiBase;
  const wsBase = parseBase(realtime ?? api,[...http,'ws:','wss:']);
  wsBase.protocol = ['https:','wss:'].includes(wsBase.protocol) ? 'https:' : 'http:';
  wsBase.pathname = wsBase.pathname.replace(/\/+$/, '');
  const wsTarget = realtime && wsBase.pathname.endsWith('/_ws') ? wsBase : route(wsBase,'/_ws');
  if (origin && parseBase(origin,http).origin !== origin) throw new Error('Expected an exact browser origin without path.');
  const tasks = [
    ['api', () => apiStatus(route(apiBase,'/api/ready'))],
    ['media', () => mediaStatus(route(mediaBase,'/storage/default-avatar.png'),origin)],
    ['realtime', () => realtimeStatus(wsTarget,origin)],
  ];
  if (origin && origin !== apiBase.origin) tasks.push(['apiCors', () => apiCors(route(apiBase,'/api/v2/users/me'),origin)]);
  const results = await Promise.all(tasks.map(async ([name,run]) => {
    try { return [name,await run()]; }
    catch (error) {
      const code = error.cause?.code ?? error.code;
      const timedOut = ['TimeoutError','AbortError'].includes(error.name) ||
        ['ETIMEDOUT','UND_ERR_CONNECT_TIMEOUT'].includes(code);
      return [name,failed(null,timedOut ? 'request-timeout' : 'connection-failed')];
    }
  }));
  return {ok:results.every(([,result]) => result.ok), checks:Object.fromEntries(results)};
}

function options(args) {
  const names = new Set(['api','media','realtime','origin']);
  const values = {};
  for (let index = 0; index < args.length; index += 2) {
    const token = args[index];
    const name = token.slice(2);
    const value = args[index+1];
    if (!token.startsWith('--') || !names.has(name) || !value || Object.hasOwn(values,name)) return null;
    values[name] = value;
  }
  return values.api ? values : null;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const input = options(process.argv.slice(2));
  if (!input) {
    console.error('Usage: node scripts/check-deployment-endpoints.mjs --api BASE [--media BASE] [--realtime BASE] [--origin ORIGIN]');
    process.exitCode = 2;
  } else {
    try {
      const report = await checkDeploymentEndpoints(input);
      console.log(JSON.stringify(report));
      if (!report.ok) process.exitCode = 1;
    } catch {
      console.error('Invalid deployment endpoint or browser origin.');
      process.exitCode = 2;
    }
  }
}
