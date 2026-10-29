import assert from 'node:assert/strict';
import {test} from 'node:test';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {Readable} from 'node:stream';
import {ServerResponse} from 'node:http';
import {createRequire} from 'node:module';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {build} from 'esbuild';
import {createError,createEvent} from 'h3';

const root=fileURLToPath(new URL('../',import.meta.url)),require=createRequire(import.meta.url);
const stubs={
 '~/server/storage': `export const STORAGE_MEDIA_MAX_SIZE=32;
   export const ensureStorageTempDir=()=>globalThis.__mediaUpload.ensureTemp();
   export const storePostMediaFile=(user,file)=>globalThis.__mediaUpload.store(user,file);
   export const deleteStorageReference=input=>globalThis.__mediaUpload.remove(input);`,
 '~/server/models/v2': `export const v2EnsureMediaDescriptionColumn=()=>globalThis.__mediaUpload.readiness();export const v2MapMedia=row=>globalThis.__mediaUpload.map(row);`,
 './api-cache': `export const readApiResponseCache=async()=>({status:'disabled'}),writeApiResponseCache=async()=>{},invalidateApiResponseCache=async()=>{},shouldInvalidateApiResponseCache=()=>false;`,
 './logging': `export const getRequestLogContext=()=>null,logError=()=>{},logInfo=()=>{},serializeLogError=()=>({});`,
 oracledb:'export default {OUT_FORMAT_OBJECT:4002};'
};
const compiled=await build({stdin:{contents:`export {default} from './server/api/v2/media/index.post';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'media-upload-boundaries',setup(builder){
 builder.onResolve({filter:/.*/},args=>{if(Object.hasOwn(stubs,args.path))return{path:args.path,namespace:'stub'};if(args.path==='formidable')return{path:import.meta.resolve('formidable'),external:true};if(args.path.startsWith('~/'))return{path:path.join(root,`${args.path.slice(2)}.ts`)};if(args.path.startsWith('node:'))return{path:args.path,external:true};if(!args.path.startsWith('.')&&!path.isAbsolute(args.path))return{path:pathToFileURL(require.resolve(args.path)).href,external:true};});
 builder.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:stubs[args.path],loader:'js'}));
}}]});
const route=(await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`)).default;
function multipart(files){const boundary='NekoTribe-upload-test';let text='';for(const file of files)text+=`--${boundary}\r\nContent-Disposition: form-data; name="${file.field??'file'}"; filename="${file.name??'fixture.txt'}"\r\nContent-Type: text/plain\r\n\r\n${file.body??'abc'}\r\n`;text+=`--${boundary}\r\nContent-Disposition: form-data; name="alt_text"\r\n\r\nalt\r\n--${boundary}--\r\n`;return{body:Buffer.from(text),type:`multipart/form-data; boundary=${boundary}`};}
async function fixture(mode='',rollbackFail=false){
 const directory=await fs.mkdtemp(path.join(os.tmpdir(),'nekotribe-media-lifecycle-'));const temporary=path.join(directory,'temp'),objects=path.join(directory,'objects');await fs.mkdir(temporary);await fs.mkdir(objects);
 const state={mode,rollbackFail,directory,temporary,objects,stored:false,pending:false,persisted:false,commits:0,rollbacks:0,removed:0,selected:null,binds:null,maps:0};
 const fail=stage=>{if(mode===stage)throw new Error('private database path password detail');};
 return Object.assign(state,{
  async ensureTemp(){fail('temp');return temporary;},
  async store(user,file){assert.equal(user,42);fail('store');state.selected=file.originalFilename;await fs.copyFile(file.filepath,path.join(objects,'new.txt'));await fs.rm(file.filepath);state.stored=true;return{mediaType:'file',originalName:file.originalFilename,key:'new.txt',url:'/storage/new.txt',size:3,contentType:'text/plain',metadata:{width:null,height:null,duration:null},thumbnailUrl:null};},
  async remove(input){assert.deepEqual(input,{storageKey:'new.txt'});state.removed++;fail('cleanup');await fs.rm(path.join(objects,'new.txt'),{force:true});state.stored=false;},
  async readiness(){fail('schema');},map(row){state.maps++;fail('map');return{media_id:row.MEDIA_ID,public_url:'/storage/new.txt'};},
  async execute(sql,binds={},options={}){
   sql=sql.replace(/\s+/g,' ').trim();
   if(sql.startsWith('SELECT seq_media_id')){fail('sequence');return{rows:[{ID:99}]};}
   if(sql.startsWith('INSERT INTO n_media_assets')){assert.equal(options.autoCommit,false);state.binds=binds;state.pending=true;fail('insert');return{rowsAffected:1};}
   if(sql.startsWith('SELECT * FROM n_media_assets')){fail('read');return{rows:mode==='missing-row'?[]:[{MEDIA_ID:99}]};}
   throw new Error('unexpected SQL');
  },
  async commit(){state.commits++;fail('commit');state.persisted=state.pending;state.pending=false;fail('commit-applied');},
  async rollback(){state.rollbacks++;if(rollbackFail)throw new Error('private rollback failure');state.pending=false;},
  async close(){fail('close');},
  async dispose(){const target=path.resolve(directory);assert.equal(path.dirname(target),path.resolve(os.tmpdir()));assert.ok(path.basename(target).startsWith('nekotribe-media-lifecycle-'));await fs.rm(target,{recursive:true,force:true,maxRetries:3,retryDelay:10});}
 });
}
async function invoke(state,files=[{}],{auth=true,type=null}={}){
 globalThis.__mediaUpload=state;const data=multipart(files);const request=Readable.from([data.body]);request.method='POST';request.url='/api/v2/media';request.headers={'content-type':type??data.type,'content-length':String(data.body.length)};
 const response=new ServerResponse(request),event=createEvent(request,response);if(auth)event.context.auth={userId:42};event.context.getOracleConnection=async()=>state;
 try{return await route(event);}finally{response.destroy();delete globalThis.__mediaUpload;}
}
test('multipart success maps once, commits once and removes all request temporary files',async()=>{
 const state=await fixture();try{const result=await invoke(state,[{field:'media',name:'ignored.txt'},{field:'file',name:'chosen.txt'}]);assert.equal(result.message,'media uploaded');assert.equal(state.selected,'chosen.txt');assert.equal(state.commits,1);assert.equal(state.maps,1);assert.equal(state.persisted,true);assert.equal(state.stored,true);assert.equal(state.binds.alt_text,'alt');assert.deepEqual(await fs.readdir(state.temporary),[]);}finally{await state.dispose();}
});
for(const mode of ['sequence','schema','insert','read','missing-row','map'])test(`pre-commit failure compensates only the new stored object: ${mode}`,async()=>{
 const state=await fixture(mode);try{await assert.rejects(invoke(state),error=>error.statusCode===500&&!error.message.includes('private'));assert.equal(state.stored,false);assert.equal(state.removed,1);assert.equal(state.persisted,false);assert.deepEqual(await fs.readdir(state.temporary),[]);}finally{await state.dispose();}
});
for(const mode of ['commit','commit-applied','close'])test(`uncertain or completed commit preserves the stored object: ${mode}`,async()=>{
 const state=await fixture(mode);try{await assert.rejects(invoke(state),error=>error.statusCode===500&&!error.message.includes('private'));assert.equal(state.stored,true);assert.equal(state.removed,0);assert.equal(state.commits,1);assert.equal(state.persisted,mode!=='commit');assert.deepEqual(await fs.readdir(state.temporary),[]);}finally{await state.dispose();}
});
test('rollback failure preserves the object for later reconciliation',async()=>{
 const state=await fixture('insert',true);try{await assert.rejects(invoke(state),error=>error.statusCode===500);assert.equal(state.stored,true);assert.equal(state.removed,0);assert.deepEqual(await fs.readdir(state.temporary),[]);}finally{await state.dispose();}
});
test('rollback failure overrides a public schema error with a safe internal error',async()=>{
 const state=await fixture('',true);state.readiness=async()=>{throw createError({statusCode:503,statusMessage:'Service temporarily unavailable',data:{code:50301,message:'服务暂不可用，请稍后重试。',data:null,meta:null}})};
 try{await assert.rejects(invoke(state),error=>error.statusCode===500);assert.equal(state.stored,true);assert.equal(state.removed,0);}finally{await state.dispose();}
});
test('missing files, parser size errors and failed file storage leave no temporary files',async()=>{
 for(const [mode,files,status]of [['',[],400],['',[{body:'a'.repeat(64)}],400],['store',[{}],500]]){const state=await fixture(mode);try{await assert.rejects(invoke(state,files),error=>error.statusCode===status&&!error.message.includes('private'));assert.deepEqual(await fs.readdir(state.temporary),[]);}finally{await state.dispose();}}
});
test('authentication and multipart validation precede storage work',async()=>{
 const state=await fixture('temp');try{await assert.rejects(invoke(state,[{}],{auth:false}),error=>error.statusCode===401);await assert.rejects(invoke(state,[{}],{type:'application/json'}),error=>error.statusCode===400);assert.equal(state.stored,false);}finally{await state.dispose();}
});
