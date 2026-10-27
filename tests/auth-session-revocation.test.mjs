// Actual Nuxt H3 middleware/routes/service/JWT. Oracle and external boundaries
// are isolated; these cases are not real database acceptance.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createServer, request as httpRequest } from 'node:http';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { test } from 'node:test';
import { build } from 'esbuild';
import { createApp, createRouter, defineEventHandler, toNodeListener, createEvent, setResponseHeader } from 'h3';
import { IncomingMessage, ServerResponse } from 'node:http';
import { Socket } from 'node:net';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const fixture = JSON.parse(readFileSync(new URL('../specifications/scenarios/auth-session-revocation.json', import.meta.url)));
const marker = 'synthetic-never-print-credential';
const cacheStub = 'export const readApiResponseCache = async () => ({status:"bypass",reason:"isolated"}); export const writeApiResponseCache = async () => {}; export const invalidateApiResponseCache = async () => {}; export const shouldInvalidateApiResponseCache = () => false;';
const loggingStub = 'export const getRequestLogContext = () => null; export const logError = () => {}; export const logInfo = () => {}; export const logWarn = () => {}; export const serializeLogError = () => ({});';
const stubs = {
  '#imports': `export const useRuntimeConfig = () => ({accessSecret:${JSON.stringify(fixture.keys.access)},refreshSecret:${JSON.stringify(fixture.keys.refresh)}});`,
  jsonwebtoken: `import jwt from ${JSON.stringify(pathToFileURL(require.resolve('jsonwebtoken')).href)}; export default {...jwt,verify(token,key,options){return jwt.verify(token,key,{...options,clockTimestamp:${fixture.now}})}};`,
  '~/server/models/v2': 'export const v2RequireSelfUser = async () => {throw new Error("profile boundary must not be called")};',
  './notifications': 'export const v2CreateNotification = async () => {throw new Error("notifications boundary must not be called")};',
  './logging': loggingStub,
  oracledb: 'export default {OUT_FORMAT_OBJECT:4002};',
  nodemailer: 'export default {createTransport(){throw new Error("mail boundary must not be called")}};'
};
const compiled = await build({
  stdin: { contents: `
    export {default as auth} from './server/middleware/auth';
    export {default as cors} from './server/middleware/00-cors';
    export {default as revoke} from './server/api/v2/auth/sessions/[id].delete';
    export {default as others} from './server/api/v2/auth/sessions/others.delete';
    export {readApiResponseCache} from './server/utils/api-cache';
    export {createRequestLogContext as requestLogContext,logInfo as actualLogInfo,logWarn as actualLogWarn,logError as actualLogError} from './server/utils/logging';
  `, resolveDir: root, loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'session-boundaries', setup(builder) {
    builder.onResolve({filter: /.*/}, args => {
      if (args.path === './api-cache' && args.importer.endsWith('v2.ts')) return {path:'route-cache-isolation',namespace:'session-stub'};
      if (Object.hasOwn(stubs,args.path)) return {path:args.path,namespace:'session-stub'};
      if (args.path.startsWith('file:') || args.path.startsWith('node:') || args.path === 'crypto') return {path:args.path,external:true};
      if (args.path.startsWith('~/')) return {path:path.join(root,`${args.path.slice(2)}.ts`)};
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) return {path:pathToFileURL(require.resolve(args.path)).href,external:true};
    });
    builder.onLoad({filter:/.*/,namespace:'session-stub'},args=>({contents:args.path==='route-cache-isolation'?cacheStub:stubs[args.path],loader:'js'}));
  }}]
});
const routes = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

function database(item, closeFailure = false) {
  const rows = structuredClone(item.sessions);
  const state = {rows,touches:0,revokes:0,errors:[],closed:0};
  state.connection = () => ({
    async execute(statement, binds, options) {
      assert.equal(options.autoCommit,true);
      const sql = statement.replace(/\s+/g,' ').trim();
      assert(sql.startsWith('UPDATE n_auth_sessions SET '));
      if (sql.includes('SET last_accessed_at')) {
        state.touches++;
        if (item.fault === 'touch') throw new Error(marker);
        const row = rows.find(row=>row.userId === binds.userId && row.sessionId === binds.sessionId && row.accessJti === binds.accessJti && row.revokedAt === null && row.accessExpiresAt > fixture.now);
        assert(sql.includes('access_token_expires_at > CURRENT_TIMESTAMP'));
        if (row) row.lastAccessedAt = fixture.now;
        return {rowsAffected:row?1:0};
      }
      state.revokes++;
      if (item.fault === 'revoke') throw new Error(marker);
      assert(sql.includes('revoked_at IS NULL'));
      const others = sql.includes('session_id !=');
      const selected = rows.filter(row=>row.userId === binds.user_id && row.revokedAt === null && (others ? row.sessionId !== binds.session_id : row.sessionId === binds.session_id));
      for (const row of selected) row.revokedAt = fixture.now;
      return {rowsAffected:selected.length};
    },
    async close() { state.closed++; if(closeFailure || (item.fault==='service-close' && state.closed>1)) throw new Error(marker); }
  });
  return state;
}
async function withServer(item, run, closeFailure = false) {
  const db = database(item,closeFailure);
  const app = createApp({onError(error){db.errors.push({statusCode:error.statusCode,message:error.message})}});
  app.use(defineEventHandler(event=>{event.context.getOracleConnection=async()=>{
    if(item.fault==='service-open' && db.closed>0) throw new Error(marker);
    return db.connection();
  }; if(item.initialCookies) setResponseHeader(event,'set-cookie',item.initialCookies)}));
  app.use(routes.cors); app.use(routes.auth);
  const router = createRouter();
  router.delete('/api/v2/auth/sessions/others',routes.others);
  router.delete('/api/v2/auth/sessions/:id',routes.revoke);
  app.use(router);
  const server = createServer(toNodeListener(app));
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  try {await run(`http://127.0.0.1:${server.address().port}`,db)}
  finally {server.closeAllConnections(); await new Promise(resolve=>server.close(resolve))}
}
function clearedCookies(response) {
  return response.headers.getSetCookie().map(cookie=>{
    const name=cookie.split('=',1)[0];
    assert(cookie.startsWith(`${name}=`)); assert(/(?:^|;)\s*Max-Age=0(?:;|$)/i.test(cookie)); assert(/(?:^|;)\s*Path=\/(?:;|$)/i.test(cookie));
    return name;
  }).sort();
}
async function requestFixture(origin, request) {
  if (!request.cookieFields) return fetch(origin+request.path,{method:request.method,headers:request.headers});
  return new Promise((resolve,reject)=>{
    const outgoing=httpRequest(origin+request.path,{method:request.method,headers:{...request.headers,cookie:request.cookieFields}},response=>{
      const chunks=[];
      response.on('data',chunk=>chunks.push(chunk));
      response.on('error',reject);
      response.on('end',()=>resolve({status:response.statusCode,headers:{getSetCookie:()=>response.headers['set-cookie']??[]},json:async()=>JSON.parse(Buffer.concat(chunks).toString('utf8'))}));
    });
    outgoing.on('error',reject);outgoing.end();
  });
}
assert.equal(fixture.cases.length,29);
for(const item of fixture.cases) {
  test(`Nuxt session revocation: ${item.id}`,async()=>withServer(item,async(origin,db)=>{
    for(const request of item.requests) {
      const response=await requestFixture(origin,request);
      assert.equal(response.status,request.expectedStatus);
      const body=await response.json();
      const envelope=body.code===undefined?body.data:body;
      if(request.expectedEnvelope) assert.deepEqual(envelope,request.expectedEnvelope);
      assert.deepEqual(clearedCookies(response),[...request.expectedClearedCookies].sort());
      assert(!JSON.stringify(body).includes(marker));
    }
    assert.equal(db.touches,item.expectedTouches); assert.equal(db.revokes,item.expectedRevokes);
    assert.deepEqual(db.rows.filter(row=>row.revokedAt!==null).map(row=>row.sessionId).sort(),item.expectedRevokedSessionIds);
    assert.deepEqual(db.rows.filter(row=>row.lastAccessedAt===fixture.now).map(row=>row.sessionId).sort(),item.expectedTouchedSessionIds);
    assert(!JSON.stringify(db.errors).includes(marker),'internal Oracle errors must be sanitized before framework logging');
  }));
}
test('auth close failure becomes safe 401 before a session mutation',async()=>withServer(fixture.cases[0],async(origin,db)=>{
  const request=fixture.cases[0].requests[0];
  const response=await fetch(origin+request.path,{method:request.method,headers:request.headers});
  assert.equal(response.status,401);
  const body=await response.json(); assert.equal(body.data.code,40101);
  assert.equal(db.touches,1); assert.equal(db.revokes,0);
  assert(!JSON.stringify(db.errors).includes(marker));
},true));
test('session list bypasses all response Redis reads',async()=>{
  const socket=new Socket();const request=new IncomingMessage(socket);request.url='/api/v2/auth/sessions';request.method='GET';
  const response=new ServerResponse(request);const event=createEvent(request,response);
  let reads=0;
  event.context.auth={userId:42,sessionId:'current'};
  event.context.redis={async mget(){reads++;return[]},async get(){reads++;return null}};
  try {assert.deepEqual(await routes.readApiResponseCache(event,'v2'),{status:'bypass',reason:'not_cacheable'});assert.equal(reads,0)}
  finally {response.destroy();socket.destroy()}
});
test('session contract defines opaque string IDs',()=>{
  const spec=JSON.parse(readFileSync(new URL('../doc/v2.openapi.json',import.meta.url)));
  const operation=Object.values(spec.paths).flatMap(path=>Object.values(path)).find(operation=>operation?.operationId==='delete_auth_sessions_id');
  assert.equal(operation.parameters.find(parameter=>parameter.name==='id').schema.type,'string');
});
for(const fault of ['service-open','service-close']) {
  test(`session connection ${fault} has a safe failure boundary`,async()=>withServer({...fixture.cases[0],fault},async(origin,db)=>{
    const request=fixture.cases[0].requests[0];
    const response=await fetch(origin+request.path,{method:request.method,headers:request.headers});
    assert.equal(response.status,500);
    const body=await response.json();assert.equal(body.data?.code,50001);
    assert(!JSON.stringify(db.errors).includes(marker));
    assert.equal(db.rows.find(row=>row.sessionId==='peer').revokedAt!==null,fault==='service-close');
  }));
}
test('self revoke followed by connection close failure does not publish cookie changes',async()=>withServer({...fixture.cases.find(item=>item.id==='SESSION-R006'),fault:'service-close'},async(origin,db)=>{
  const request=fixture.cases.find(item=>item.id==='SESSION-R006').requests[0];
  const response=await fetch(origin+request.path,{method:request.method,headers:request.headers});
  assert.equal(response.status,500);
  assert.deepEqual(response.headers.getSetCookie(),[]);
  assert.notEqual(db.rows.find(row=>row.sessionId==='fixture-session-42').revokedAt,null);
}));
test('connection cleanup failure preserves cookies from earlier middleware',async()=>{
  const item={...fixture.cases.find(item=>item.id==='SESSION-R006'),fault:'service-close',initialCookies:['earlier=preserved; Path=/']};
  await withServer(item,async origin=>{
    const request=item.requests[0];
    const response=await fetch(origin+request.path,{method:request.method,headers:request.headers});
    assert.equal(response.status,500);
    assert.deepEqual(response.headers.getSetCookie(),item.initialCookies);
  });
});
test('session resource paths are redacted in inherited request logging',()=>{
  const socket=new Socket();const request=new IncomingMessage(socket);
  request.url='/api/v2/auth/sessions/private-session-fixture?access_token=private-token-fixture';request.method='DELETE';request.headers={host:'localhost'};
  const response=new ServerResponse(request);const event=createEvent(request,response);
  const original={info:console.info,warn:console.warn,error:console.error};const records=[];
  try {
    for(const key of Object.keys(original)) console[key]=(...args)=>records.push(JSON.stringify(args));
    const context=routes.requestLogContext(event);
    assert.equal(context.path,'/api/v2/auth/sessions/[session]');
    assert(!context.rawUrl.includes('private-session-fixture'));assert(!context.rawUrl.includes('private-token-fixture'));
    for(const logger of [routes.actualLogInfo,routes.actualLogWarn,routes.actualLogError]) logger('test',{path:'/api/v2/auth/sessions/private-session-fixture',rawUrl:request.url});
    assert.equal(records.length,3);assert(!records.join('').includes('private-session-fixture'));assert(!records.join('').includes('private-token-fixture'));
    assert.equal(request.url,'/api/v2/auth/sessions/private-session-fixture?access_token=private-token-fixture');
  } finally {Object.assign(console,original);response.destroy();socket.destroy()}
});
