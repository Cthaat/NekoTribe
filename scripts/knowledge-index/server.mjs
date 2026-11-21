import { createHash, timingSafeEqual } from 'node:crypto';
import { createServer } from 'node:http';
import { isIP } from 'node:net';
import { credential, readProfile, verificationText } from './config.mjs';
import { readJson, requestJson } from './http.mjs';
import { assertMatchingProbe, embed } from './embedding.mjs';
import { indexStore, indexStoreConnection } from './qdrant.mjs';

const endpoint = '/internal/v1/knowledge/search';
const readinessEndpoint = '/internal/v1/knowledge/ready';
const hash = value => createHash('sha256').update(value).digest();

function respond(response, status, payload) {
  if (response.destroyed) return;
  response.writeHead(status,{'content-type':'application/json; charset=utf-8','cache-control':'no-store'});
  response.end(JSON.stringify(payload));
}

function parseQuery(value) {
  if (!value || Object.keys(value).length !== 2 || typeof value.query !== 'string' || !value.query.isWellFormed() ||
      !Number.isInteger(value.limit) || value.limit < 1 || value.limit > 20) throw Error('INVALID_QUERY');
  const query = value.query.trim();
  if (!query || Buffer.byteLength(query) > 256 || /[\u0000-\u001f\u007f]/.test(query)) throw Error('INVALID_QUERY');
  return {query,limit:value.limit};
}

function serviceToken() {
  const token = credential(process.env.AI_INDEX_SERVICE_TOKEN);
  if (token.length < 32) throw Error('SERVICE_TOKEN_TOO_SHORT');
  return token;
}

function listenAddress() {
  const port = Number(process.env.AI_INDEX_PORT ?? 3818);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw Error('INVALID_PORT');
  return { host:process.env.AI_INDEX_HOST || '127.0.0.1', port };
}

export async function checkIndexReadiness() {
  const { host, port } = listenAddress();
  const address = host === '0.0.0.0' ? '127.0.0.1' : host === '::' ? '::1' : host;
  const authority = isIP(address) === 6 ? `[${address}]` : address;
  const url = new URL(`http://localhost:${port}${readinessEndpoint}`);
  url.hostname = authority;
  if (url.hostname !== authority.toLowerCase() && isIP(address) !== 6) throw Error('INVALID_HOST');
  const result = await requestJson(url,{headers:{authorization:`Bearer ${serviceToken()}`},timeout:5000,limit:256});
  if (result?.version !== 1 || result.ready !== true) throw Error('INDEX_RESPONSE_INVALID');
}

export async function startIndexServer(activePath) {
  const expected = hash(`Bearer ${serviceToken()}`);
  const { host, port } = listenAddress();
  // The first activation may be published while the server is already listening.
  indexStoreConnection();
  try {
    await readProfile(activePath);
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }

  async function checkCompleteIndex() {
    const signal = AbortSignal.timeout(4500);
    const store = indexStore(await readProfile(activePath));
    const {points} = await store.checkMarker(signal);
    if (!await store.hasExpectedPoints(points,signal)) throw Error('INDEX_INCOMPLETE');
  }

  let active = 0;
  let readiness;
  const server = createServer({requestTimeout:12000,headersTimeout:5000,maxHeaderSize:8192}, async (request,response) => {
    const reject = (status,code) => {
      response.shouldKeepAlive = false;
      respond(response,status,{version:1,error:code});
    };
    const checkingReadiness = request.method === 'GET' && request.url === readinessEndpoint;
    if (!checkingReadiness && (request.method !== 'POST' || request.url !== endpoint)) return reject(404,'not_found');
    const auth = request.headers.authorization ?? '';
    if (!timingSafeEqual(hash(auth),expected)) return reject(401,'unauthorized');
    if (checkingReadiness) {
      response.shouldKeepAlive = false;
      readiness ??= checkCompleteIndex().finally(() => { readiness = undefined; });
      try {
        await readiness;
        return respond(response,200,{version:1,ready:true});
      } catch {
        return reject(503,'unavailable');
      }
    }
    if (active >= 8) return reject(429,'busy');
    active++;
    const controller = new AbortController();
    const cancel = () => controller.abort();
    let bodyComplete = false;
    const timeout = setTimeout(()=>{
      cancel();
      if (!bodyComplete) request.destroy();
    },10000);
    response.once('close',cancel);
    const signal = controller.signal;
    try {
      let input;
      try {
        const contentType = request.headers['content-type']?.split(';',1)[0]?.trim().toLowerCase();
        if (contentType !== 'application/json') throw Error('INVALID_QUERY');
        input = parseQuery(await readJson(request.iterator({destroyOnReturn:false}),2048));
        bodyComplete = true;
      } catch {
        return reject(400,'invalid_query');
      }
      const snapshot = await readProfile(activePath);
      const store = indexStore(snapshot);
      const {points,vector:storedProbe} = await store.readEmbeddingMarker(signal);
      if (!await store.hasExpectedPoints(points,signal)) throw Error('INDEX_INCOMPLETE');
      const [probe,vector] = await embed(snapshot,[verificationText,input.query],{signal});
      assertMatchingProbe(snapshot,storedProbe,probe);
      const includeGroups = request.headers['x-neko-knowledge-group-sources'] === '1';
      const hits = await store.search(vector,input.limit,signal,{includeGroups});
      const candidates = request.headers['x-neko-knowledge-chunks'] === '1'
        ? hits : hits.map(({kind,id,version})=>({kind,id,version}));
      respond(response,200,{version:1,candidates});
    } catch {
      reject(503,'unavailable');
    } finally {
      clearTimeout(timeout);
      response.off('close',cancel);
      active--;
    }
  });
  await new Promise((resolve,reject)=>{
    server.once('error',reject);
    server.listen(port,host,()=>{
      server.off('error',reject);
      resolve();
    });
  });
  return server;
}
