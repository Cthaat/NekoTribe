import assert from 'node:assert/strict';
import {test} from 'node:test';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {readFileSync} from 'node:fs';
import {createServer} from 'node:http';
import {fileURLToPath} from 'node:url';
import {build} from 'esbuild';
import {createApp, createError, createRouter, defineEventHandler, getRouterParam, toNodeListener} from 'h3';
const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:`export {normalizeLocalStorageKey} from './server/storage/local-path';export {parseLocalByteRange} from './server/storage/http';export {LocalStorageProvider} from './server/storage/providers/local';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm'});
const library=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/storage-local-policy.json',import.meta.url),'utf8'));
test('retired upload links return the original encoded path and no HEAD body',async t=>{
 const compiled=await build({
  stdin:{contents:`
   export {default as uploadGet} from './server/routes/upload/[...segments].get';
   export {default as uploadHead} from './server/routes/upload/[...segments].head';
   export {default as uploadsGet} from './server/routes/uploads/[...segments].get';
   export {default as uploadsHead} from './server/routes/uploads/[...segments].head';`,resolveDir:root,loader:'ts'},
  bundle:true,write:false,platform:'node',format:'esm',
  plugins:[{name:'resolve-h3',setup(builder){
   builder.onResolve({filter:/^h3$/},()=>({path:import.meta.resolve('h3'),external:true}));
  }}],
 });
 const handlers=await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
 const router=createRouter();
 for(const name of ['upload','uploads']){
  router.get(`/${name}/**:segments`,handlers[`${name}Get`]);
  router.head(`/${name}/**:segments`,handlers[`${name}Head`]);
 }
 const server=createServer(toNodeListener(createApp().use(router)));
 await new Promise((resolve,reject)=>server.listen(0,'127.0.0.1',resolve).once('error',reject));
 t.after(()=>new Promise(resolve=>server.close(resolve)));
 for(const name of ['upload','uploads']){
  const requested_path=`/${name}/images/cat%20photo.png`;
  const url=`http://127.0.0.1:${server.address().port}${requested_path}?ignored=1`;
  const get=await fetch(url);
  assert.equal(get.status,410);
  assert.equal(get.headers.get('cache-control'),'no-store');
  assert.deepEqual(await get.json(),{
   code:410,message:`Legacy /${name} path removed. Public files are served from /storage.`,
   data:{requested_path,storage_base:'/storage'},meta:null
  });
  const head=await fetch(url,{method:'HEAD'});
  assert.equal(head.status,410);
  assert.equal(head.headers.get('cache-control'),'no-store');
  assert.equal(await head.text(),'');
 }
});
for(const vector of vectors.cases)test(`local storage policy: ${vector.id}`,()=>{
 const invoke=()=>vector.kind==='key'?library.normalizeLocalStorageKey(vector.value):library.parseLocalByteRange(vector.value,vector.size);
 if(vector.expected.status!==200)assert.throws(invoke,error=>error.statusCode===vector.expected.status);
 else assert.deepEqual(invoke(),vector.kind==='key'?vector.expected.key:vector.expected.range);
});
async function fixture(){
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'nekotribe-local-files-'));const root=path.join(dir,'root'),outside=path.join(dir,'outside');await fs.mkdir(root);await fs.mkdir(outside);await fs.writeFile(path.join(outside,'secret.txt'),'outside private fixture');const provider=new library.LocalStorageProvider({type:'local',rootPath:root,publicBasePath:'/storage',publicBaseUrl:null,cdnBaseUrl:null});
 return{dir,root,outside,provider,async dispose(){assert.equal(path.dirname(path.resolve(dir)),path.resolve(os.tmpdir()));assert.ok(path.basename(dir).startsWith('nekotribe-local-files-'));await fs.rm(dir,{recursive:true,force:true,maxRetries:3,retryDelay:10});}};
}
test('public media HEAD uses the shared MIME table', async t => {
 const f = await fixture();
 t.after(() => f.dispose());
 await fs.mkdir(path.join(f.root, 'posts'));
 for (const [key, type] of Object.entries(vectors.publicContentTypes)) {
  await fs.writeFile(path.join(f.root, key), 'fixture');
  const result = await f.provider.readObject(key, {headOnly:true});
  assert.equal(result.headers['Content-Type'], type, key);
 }
});
test('local provider reads ordinary files and streams only the requested range',async()=>{
 const f=await fixture();try{await fs.mkdir(path.join(f.root,'folder'));await fs.writeFile(path.join(f.root,'folder','file.txt'),'abcdefghij');const result=await f.provider.readObject('folder/file.txt',{rangeHeader:'bytes=2-4'});let text='';for await(const chunk of result.stream)text+=chunk;assert.equal(text,'cde');assert.equal(result.statusCode,206);assert.equal(result.headers['Content-Length'],'3');assert.equal(result.headers['Content-Range'],'bytes 2-4/10');assert.equal(result.headers['X-Content-Type-Options'],'nosniff');}finally{await f.dispose();}
});
test('reserved storage is never read or published as public media', async t => {
 const f = await fixture();
 t.after(() => f.dispose());
 await fs.mkdir(path.join(f.root, 'Private'));
 const source = path.join(f.outside, 'secret.txt');
 await fs.copyFile(source, path.join(f.root, 'Private', 'secret.txt'));

 for (const key of ['Private/secret.txt', 'Private\\secret.txt']) {
  for (const request of [{}, {headOnly:true}, {rangeHeader:'bytes=0-1'}]) {
   await assert.rejects(f.provider.readObject(key, request), {statusCode:404});
  }
  assert.throws(() => f.provider.getPublicUrl(key), {statusCode:404});
 }
 await assert.rejects(f.provider.saveFromPath({
  key:'posts/new.txt', sourcePath:source, contentType:'text/plain', visibility:'private'
 }), {statusCode:400});
 assert.equal(await fs.readFile(source, 'utf8'), 'outside private fixture');
 await assert.rejects(fs.stat(path.join(f.root, 'posts')), {code:'ENOENT'});
 const key = 'private/chat/42/file.txt';
 await assert.rejects(f.provider.saveFromPath({key, sourcePath:source, contentType:'text/plain'}), {statusCode:404});
 const stored = await f.provider.saveFromPath({key, sourcePath:source, contentType:'text/plain', visibility:'private'});
 assert.equal(stored.url, '');
 assert.equal(stored.visibility, 'private');
 assert.equal(await fs.readFile(path.join(f.root, key), 'utf8'), 'outside private fixture');
 await assert.rejects(f.provider.readObject(key, {}), {statusCode:404});
 await f.provider.deleteObject(key);
 await assert.rejects(fs.stat(path.join(f.root, key)), {code:'ENOENT'});
});
test('HEAD route returns local and S3 metadata and handles the default avatar',async t=>{
 const f=await fixture();
 t.after(()=>f.dispose());
 await fs.writeFile(path.join(f.root,'file.txt'),'abcdefghij');

 async function listen(handler){
  const server=createServer(handler);
  await new Promise((resolve,reject)=>server.listen(0,'127.0.0.1',resolve).once('error',reject));
  t.after(()=>new Promise(resolve=>server.close(resolve)));
  return `http://127.0.0.1:${server.address().port}`;
 }
 const requests=[];
 const upstream=await listen((req,res)=>{
  requests.push({method:req.method,path:req.url,range:req.headers.range});
  if (req.method === 'PUT') {
   assert.equal(req.headers['cache-control'], 'private, no-store');
   assert.equal(req.headers['if-none-match'], '*');
   req.resume();
   req.on('end', () => res.end());
   return;
  }
  if (req.method === 'DELETE') { res.writeHead(204); res.end(); return; }
  if (req.method === 'GET') {
   if (req.headers.range === 'bytes=40-') res.setHeader('Content-Range', 'bytes */10');
   res.writeHead(416);
   res.end();
   return;
  }
  res.setHeader('Content-Length','10');
  res.end();
 });
 const env={ENDPOINT:upstream,BUCKET:'fixture-media',REGION:'us-east-1',ACCESS_KEY:'fixture-key',SECRET_KEY:'fixture-secret'};
 for(const [suffix,value] of Object.entries(env)){
  const key=`STORAGE_S3_${suffix}`;
  const previous=process.env[key];
  process.env[key]=value;
  t.after(()=>{if(previous===undefined)delete process.env[key];else process.env[key]=previous;});
 }

 let provider;
 const routeGlobals={defineEventHandler,getRouterParam,createError,__storageHeadProvider:()=>provider};
 Object.assign(globalThis,routeGlobals);
 t.after(()=>{for(const key of Object.keys(routeGlobals))delete globalThis[key];});
 const compiled=await build({
  stdin:{
   contents:`export {default as head} from './server/routes/storage/[...segments].head';
   export {default as get} from './server/routes/storage/[...segments].get';
   export {default as cors} from './server/middleware/00-cors';
   export {LocalStorageProvider} from './server/storage/providers/local';
   export {S3StorageProvider} from './server/storage/providers/s3';`,
   resolveDir:root,loader:'ts'
  },
  bundle:true,write:false,platform:'node',format:'esm',
  plugins:[{name:'storage-head-fixture',setup(builder){
   builder.onResolve({filter:/^h3$/},()=>({path:import.meta.resolve('h3'),external:true}));
   builder.onResolve({filter:/^~\/server\/storage$/},()=>({path:'storage',namespace:'fixture'}));
   builder.onLoad({filter:/.*/,namespace:'fixture'},()=>({contents:`
    export const DEFAULT_AVATAR_STORAGE_KEY='default-avatar.png';
    export const managedPublicUrlToStorageKey=()=>null;
    export const getStorageProvider=()=>globalThis.__storageHeadProvider();`}));
   builder.onResolve({filter:/^~\/server\/storage\/http$/},()=>({path:path.join(root,'server/storage/http.ts')}));
  }}]
 });
 const {head,get,cors,LocalStorageProvider,S3StorageProvider}=await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
 const localConfig={type:'local',rootPath:f.root,publicBasePath:'/storage',publicBaseUrl:null,cdnBaseUrl:null};
 provider=new LocalStorageProvider(localConfig);
 const router=createRouter().head('/storage/**:segments',head).get('/storage/**:segments',get);
 const base=await listen(toNodeListener(createApp().use(cors).use(router)));
 const request=key=>fetch(`${base}/storage/${key}`,{method:'HEAD',headers:{Range:'bytes=999-'}});

 const local=await request('file.txt');
 assert.equal(local.status,200);
 assert.equal(local.headers.get('content-length'),'10');
 assert.equal(local.headers.get('accept-ranges'),'bytes');
 assert.equal(local.headers.get('content-range'),null);
 assert.equal(await local.text(),'');

 const origin = 'https://frontend.example';
 const previousOrigins = process.env.NUXT_CORS_ALLOWED_ORIGINS;
 process.env.NUXT_CORS_ALLOWED_ORIGINS = origin;
 t.after(() => {
  if (previousOrigins === undefined) delete process.env.NUXT_CORS_ALLOWED_ORIGINS;
  else process.env.NUXT_CORS_ALLOWED_ORIGINS = previousOrigins;
 });
 const objectUrl = `${base}/storage/file.txt`;
 const preflight = method => fetch(objectUrl, {method:'OPTIONS', headers:{
  Origin:origin, 'Access-Control-Request-Method':method, 'Access-Control-Request-Headers':'Range'
 }});
 const allowed = await preflight('HEAD');
 assert.equal(allowed.status, 204);
 assert.equal(allowed.headers.get('access-control-allow-origin'), origin);
 assert.equal(allowed.headers.get('access-control-allow-methods'), 'GET,HEAD,OPTIONS');
 assert.equal(allowed.headers.get('access-control-allow-headers'), 'range');
 assert.equal((await preflight('POST')).status, 403);
 for (const [range, status, contentRange] of [['bytes=2-4', 206, 'bytes 2-4/10'], ['bytes=20-', 416, 'bytes */10']]) {
  const response = await fetch(objectUrl, {headers:{Origin:origin, Range:range}});
  assert.equal(response.status, status);
  assert.equal(response.headers.get('access-control-allow-origin'), origin);
  assert.match(response.headers.get('access-control-expose-headers'), /content-range,accept-ranges/);
  assert.equal(response.headers.get('content-range'), contentRange);
  await response.text();
 }
 const fallback=await request('default-avatar.png');
 assert.equal(fallback.status,200);
 assert.equal(fallback.headers.get('content-type'),'image/png');
 assert.ok(Number(fallback.headers.get('content-length'))>0);

 provider=new S3StorageProvider({...localConfig,type:'s3'});
 const remote=await request('posts/images/42/a.txt');
 assert.equal(remote.status,200);
 assert.equal(remote.headers.get('content-length'),'10');
 assert.equal(remote.headers.get('content-range'),null);
 assert.equal(await remote.text(),'');
 assert.deepEqual(requests,[{method:'HEAD',path:'/fixture-media/posts/images/42/a.txt',range:undefined}]);

 for (const [range, methods] of [['bytes=20-', ['GET', 'HEAD']], ['bytes=40-', ['GET']], ['bytes=1-2,4-5', ['HEAD']]]) {
  const start = requests.length;
  const response = await fetch(`${base}/storage/posts/images/42/a.txt`, {headers:{Origin:origin, Range:range}});
  assert.equal(response.status, 416);
  assert.equal(response.headers.get('content-range'), 'bytes */10');
  assert.deepEqual(requests.slice(start).map(item => item.method), methods);
  await response.text();
 }

 const key = 'private/post/42/file.txt';
 const writesStart = requests.length;
 const sourcePath = path.join(f.dir, 'private.txt');
 await fs.writeFile(sourcePath, 'fixture');
 const stored = await provider.saveFromPath({key, sourcePath, visibility:'private', contentType:'text/plain'});
 assert.equal(stored.url, '');
 assert.equal((await request(key)).status, 404);
 await assert.rejects(provider.readObject(key, {}), {statusCode:404});
 await provider.deleteObject(key);
 assert.deepEqual(requests.slice(writesStart).map(({method,path}) => [method,path]), [
  ['PUT', '/fixture-media/private/post/42/file.txt'],
  ['DELETE', '/fixture-media/private/post/42/file.txt'],
 ]);

 await fs.mkdir(path.join(f.root, 'posts'));
 await fs.writeFile(path.join(f.root, 'posts', 'existing.txt'), 'must stay local');
 delete process.env.STORAGE_S3_ENDPOINT;
 const requestCount = requests.length;
 for (const method of ['GET', 'HEAD']) {
  for (const [key, status] of [
   ['posts/existing.txt', 503], ['avatars/current.png', 503], ['posts/CON.txt', 400],
   ['Private/hidden.txt', 404], ['temp/hidden.txt', 404], ['images/cat.png', 404], ['default-avatar.png', 200],
  ]) {
   const response = await fetch(`${base}/storage/${key}`, {method});
   assert.equal(response.status, status, `${method} ${key}`);
   const body = await response.text();
   assert.ok(!body.includes('must stay local'));
   if (method === 'HEAD') assert.equal(body, '');
  }
 }
 assert.equal(requests.length, requestCount);
});
test('local provider rejects directories and emits an unsatisfied range header',async()=>{
 const f=await fixture();try{await fs.mkdir(path.join(f.root,'folder'));await fs.writeFile(path.join(f.root,'empty.txt'),'');await assert.rejects(f.provider.readObject('folder',{}),error=>error.statusCode===404);await assert.rejects(f.provider.readObject('empty.txt',{rangeHeader:'bytes=0-0'}),error=>error.statusCode===416&&error.headers['Content-Range']==='bytes */0');}finally{await f.dispose();}
});
test('directory links cannot redirect reads, writes or deletes outside the storage root',async()=>{
 const f=await fixture();try{await fs.symlink(f.outside,path.join(f.root,'linked'),process.platform==='win32'?'junction':'dir');const source=path.join(f.dir,'upload.txt');await fs.writeFile(source,'upload fixture');for(const operation of [()=>f.provider.readObject('linked/secret.txt',{}),()=>f.provider.deleteObject('linked/secret.txt'),()=>f.provider.saveFromPath({key:'linked/new.txt',sourcePath:source,contentType:'text/plain'})])await assert.rejects(operation,error=>error.statusCode===400);assert.equal(await fs.readFile(path.join(f.outside,'secret.txt'),'utf8'),'outside private fixture');assert.equal(await fs.readFile(source,'utf8'),'upload fixture');}finally{await f.dispose();}
});
test('links to directories inside the root are also rejected consistently',async()=>{
 const f=await fixture();try{await fs.mkdir(path.join(f.root,'folder'));await fs.writeFile(path.join(f.root,'folder','file.txt'),'inside');await fs.symlink(path.join(f.root,'folder'),path.join(f.root,'linked'),process.platform==='win32'?'junction':'dir');await assert.rejects(f.provider.readObject('linked/file.txt',{}),error=>error.statusCode===400);}finally{await f.dispose();}
});
test('saving a new object preserves an existing object on key collision',async()=>{
 const f=await fixture();try{const source=path.join(f.dir,'upload.txt');await fs.writeFile(source,'new');await fs.writeFile(path.join(f.root,'existing.txt'),'old');await assert.rejects(f.provider.saveFromPath({key:'existing.txt',sourcePath:source,contentType:'text/plain'}));assert.equal(await fs.readFile(path.join(f.root,'existing.txt'),'utf8'),'old');assert.equal(await fs.readFile(source,'utf8'),'new');const result=await f.provider.saveFromPath({key:'new/folder/file.txt',sourcePath:source,contentType:'text/plain'});assert.equal(result.size,3);assert.equal(result.url,'/storage/new/folder/file.txt');assert.equal(await fs.readFile(path.join(f.root,'new/folder/file.txt'),'utf8'),'new');}finally{await f.dispose();}
});
test('the request staging namespace is never publicly readable',async()=>{
 const f=await fixture();try{await fs.mkdir(path.join(f.root,'temp'));await fs.writeFile(path.join(f.root,'temp','upload.txt'),'unvalidated');await assert.rejects(f.provider.readObject('temp/upload.txt',{}),error=>error.statusCode===404);await assert.rejects(f.provider.readObject('TeMp/upload.txt',{}),error=>error.statusCode===404);}finally{await f.dispose();}
});
