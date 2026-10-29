import assert from 'node:assert/strict';
import {test} from 'node:test';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {build} from 'esbuild';
const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:`export {normalizeLocalStorageKey} from './server/storage/local-path';export {parseLocalByteRange} from './server/storage/http';export {LocalStorageProvider} from './server/storage/providers/local';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm'});
const library=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/storage-local-policy.json',import.meta.url),'utf8'));
for(const vector of vectors.cases)test(`local storage policy: ${vector.id}`,()=>{
 const invoke=()=>vector.kind==='key'?library.normalizeLocalStorageKey(vector.value):library.parseLocalByteRange(vector.value,vector.size);
 if(vector.expected.status!==200)assert.throws(invoke,error=>error.statusCode===vector.expected.status);
 else assert.deepEqual(invoke(),vector.kind==='key'?vector.expected.key:vector.expected.range);
});
async function fixture(){
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'nekotribe-local-files-'));const root=path.join(dir,'root'),outside=path.join(dir,'outside');await fs.mkdir(root);await fs.mkdir(outside);await fs.writeFile(path.join(outside,'secret.txt'),'outside private fixture');const provider=new library.LocalStorageProvider({type:'local',rootPath:root,publicBasePath:'/storage',publicBaseUrl:null,cdnBaseUrl:null});
 return{dir,root,outside,provider,async dispose(){assert.equal(path.dirname(path.resolve(dir)),path.resolve(os.tmpdir()));assert.ok(path.basename(dir).startsWith('nekotribe-local-files-'));await fs.rm(dir,{recursive:true,force:true,maxRetries:3,retryDelay:10});}};
}
test('local provider reads ordinary files and streams only the requested range',async()=>{
 const f=await fixture();try{await fs.mkdir(path.join(f.root,'folder'));await fs.writeFile(path.join(f.root,'folder','file.txt'),'abcdefghij');const result=await f.provider.readObject('folder/file.txt',{rangeHeader:'bytes=2-4'});let text='';for await(const chunk of result.stream)text+=chunk;assert.equal(text,'cde');assert.equal(result.statusCode,206);assert.equal(result.headers['Content-Length'],'3');assert.equal(result.headers['Content-Range'],'bytes 2-4/10');assert.equal(result.headers['X-Content-Type-Options'],'nosniff');}finally{await f.dispose();}
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
