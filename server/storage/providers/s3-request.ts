import { createHash, createHmac } from 'node:crypto';
import { request as httpRequest, type IncomingMessage } from 'node:http';
import { request as httpsRequest } from 'node:https';
import type { Readable } from 'node:stream';
import { StorageHttpError } from '../http';

type Method = 'PUT' | 'GET' | 'HEAD' | 'DELETE';
type Config = {endpoint: URL; bucket: string; region: string; accessKey: string; secretKey: string; sessionToken?: string};
export const emptyPayloadHash = createHash('sha256').digest('hex');
const hmac = (key: string | Buffer, value: string) => createHmac('sha256',key).update(value).digest();

export function s3Unavailable(): StorageHttpError {
  return new StorageHttpError(503,'媒体存储暂不可用');
}

function configuration(): Config {
  const env = (key: string) => process.env[`STORAGE_S3_${key}`]?.trim() ?? '';
  const address=env('ENDPOINT'), bucket=env('BUCKET'), region=env('REGION'), accessKey=env('ACCESS_KEY'), secretKey=env('SECRET_KEY');
  const sessionToken=env('SESSION_TOKEN') || undefined;
  let endpoint: URL;
  try { endpoint = new URL(address); } catch { throw s3Unavailable(); }
  if (!['http:', 'https:'].includes(endpoint.protocol) || !endpoint.hostname || endpoint.pathname !== '/' ||
      endpoint.username || endpoint.password || endpoint.search || endpoint.hash ||
      !/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(bucket) || !/^[a-z0-9-]{1,63}$/.test(region) ||
      !/^[A-Za-z0-9_+=.@-]{1,128}$/.test(accessKey) || !/^[!-~]{1,512}$/.test(secretKey) ||
      (sessionToken && !/^[!-~]{1,8192}$/.test(sessionToken))) throw s3Unavailable();
  return {endpoint,bucket,region,accessKey,secretKey,sessionToken};
}

export function validateS3Configuration(): void {
  configuration();
}

function escapeSegment(value: string) {
  return encodeURIComponent(value).replace(/[!'()*]/g,ch=>`%${ch.charCodeAt(0).toString(16).toUpperCase()}`);
}

function sign(config: Config, method: Method, path: string, digest: string, extra: Record<string,string>) {
  const date = new Date().toISOString().replace(/[:-]|\.\d{3}/g,'');
  const day = date.slice(0,8);
  const headers: Record<string,string> = {
    ...extra,host:config.endpoint.host,'x-amz-content-sha256':digest,'x-amz-date':date,
  };
  if (config.sessionToken) headers['x-amz-security-token'] = config.sessionToken;
  const keys = Object.keys(headers).sort();
  const signed = keys.join(';');
  const canonical = keys.map(key=>`${key}:${headers[key]!.trim().replace(/[ \t]+/g,' ')}\n`).join('');
  const hash = createHash('sha256').update([method,path,'',canonical,signed,digest].join('\n')).digest('hex');
  const scope = `${day}/${config.region}/s3/aws4_request`;
  const key = hmac(hmac(hmac(hmac(`AWS4${config.secretKey}`,day),config.region),'s3'),'aws4_request');
  const signature = hmac(key,`AWS4-HMAC-SHA256\n${date}\n${scope}\n${hash}`).toString('hex');
  return {...headers,authorization:`AWS4-HMAC-SHA256 Credential=${config.accessKey}/${scope},SignedHeaders=${signed},Signature=${signature}`};
}

export async function requestS3(method: Method, key: string, {digest=emptyPayloadHash,headers={},body}: {
  digest?: string; headers?: Record<string,string>; body?: Readable;
} = {}): Promise<IncomingMessage> {
  const config = configuration();
  const path = `/${config.bucket}/${key.split('/').map(escapeSegment).join('/')}`;
  const transport = config.endpoint.protocol === 'https:' ? httpsRequest : httpRequest;
  return new Promise((resolve,reject)=>{
    const request = transport(config.endpoint,{method,path,headers:sign(config,method,path,digest,headers)},resolve);
    const deadline = setTimeout(()=>request.destroy(s3Unavailable()),300000);
    deadline.unref();
    request.once('close',()=>clearTimeout(deadline));
    request.once('error',()=>reject(s3Unavailable()));
    request.setTimeout(30000,()=>request.destroy(s3Unavailable()));
    if (body) {
      body.once('error',()=>request.destroy(s3Unavailable()));
      request.once('close',()=>body.destroy());
      body.pipe(request);
    } else request.end();
  });
}
