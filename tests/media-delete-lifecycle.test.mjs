import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createRequire} from 'node:module';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';

const root=fileURLToPath(new URL('../',import.meta.url)),require=createRequire(import.meta.url);
const stubs={
 '~/server/storage':`export const STORAGE_MEDIA_MAX_SIZE=32; export const ensureStorageTempDir=async()=>{}; export const storePostMediaFile=async()=>{}; export const deleteStorageReference=input=>globalThis.__mediaDelete.remove(input);`,
 '~/server/models/v2':`export const v2EnsureMediaDescriptionColumn=async()=>{}; export const v2MapMedia=()=>({});`,
 './api-cache':`export const readApiResponseCache=async()=>({status:'disabled'}),writeApiResponseCache=async()=>{},invalidateApiResponseCache=async()=>{},shouldInvalidateApiResponseCache=()=>false;`,
 './logging':`export const getRequestLogContext=()=>null,logError=()=>{},logInfo=()=>{},serializeLogError=()=>({});`,
 oracledb:'export default {OUT_FORMAT_OBJECT:4002};'
};
const compiled=await build({stdin:{contents:`export {v2DeleteMedia} from './server/services/v2/media';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'media-delete-boundaries',setup(builder){
 builder.onResolve({filter:/.*/},args=>{if(Object.hasOwn(stubs,args.path))return{path:args.path,namespace:'stub'};if(args.path.startsWith('~/'))return{path:path.join(root,`${args.path.slice(2)}.ts`)};if(args.path.startsWith('node:'))return{path:args.path,external:true};if(!args.path.startsWith('.')&&!path.isAbsolute(args.path))return{path:pathToFileURL(require.resolve(args.path)).href,external:true};});
 builder.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:stubs[args.path],loader:'js'}));
}}]});
const {v2DeleteMedia}=await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

function fixture({rows=1,exists=true,fail=false}={}) {
 const removed=[],calls=[];
 return {removed,calls,async remove(input){removed.push(input)},async execute(sql,binds,options){
  calls.push({sql,binds,options});
  if(sql.includes('SELECT storage_key'))return{rows:exists?[{STORAGE_KEY:'post/42/a.png',PUBLIC_URL:'/storage/post/42/a.png',THUMBNAIL_URL:null}]:[]};
  if(sql.includes('DELETE FROM n_media_assets')){if(fail)throw new Error('uncertain database commit');return{rowsAffected:rows};}
  throw new Error('unexpected statement');
 }};
}
async function invoke(state) {
 globalThis.__mediaDelete=state;
 try{return await v2DeleteMedia({context:{auth:{userId:42}}},state,7)}finally{delete globalThis.__mediaDelete}
}
test('successful owned deletion cleans up after exactly one committed row',async()=>{
 const state=fixture();const result=await invoke(state);
 assert.equal(result.message,'media deleted');assert.equal(state.calls[1].options.autoCommit,true);
 assert.deepEqual(state.calls[1].binds,{media_id:7,user_id:42});
 assert.deepEqual(state.removed,[{storageKey:'post/42/a.png',publicUrl:'/storage/post/42/a.png'},{publicUrl:null}]);
});
test('missing or concurrently deleted record never removes the object',async()=>{
 for(const state of [fixture({exists:false}),fixture({rows:0})]){
  await assert.rejects(invoke(state),error=>error.statusCode===404);assert.deepEqual(state.removed,[]);
 }
});
test('unexpected row counts and uncertain commit never remove the object',async()=>{
 for(const state of [fixture({rows:2}),fixture({fail:true})]){
  await assert.rejects(invoke(state));assert.deepEqual(state.removed,[]);
 }
});
