import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createRequire} from 'node:module';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';
import {createError} from 'h3';
const root=fileURLToPath(new URL('../',import.meta.url));const require=createRequire(import.meta.url);
const bundle=await build({entryPoints:[path.join(root,'server/utils/auth-entry-errors.ts')],bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'safe-error-stubs',setup(builder){
 builder.onResolve({filter:/.*/},args=>{if(args.path==='./v2')return {path:args.path,namespace:'stub'};if(args.path.startsWith('node:'))return {path:args.path,external:true};if(!args.path.startsWith('.')&&!path.isAbsolute(args.path))return {path:pathToFileURL(require.resolve(args.path)).href,external:true};});
 builder.onLoad({filter:/.*/,namespace:'stub'},()=>({contents:'export const v2ServerError=()=>{throw new Error("safe server error")}',loader:'js'}));
}}]});
const {safeAuthEntry}=await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`);
test('notification not found remains public while driver errors are sanitized',async()=>{
 const publicError=createError({statusCode:404,message:'通知不存在',data:{code:40401,message:'通知不存在',data:null,meta:null}});
 await assert.rejects(safeAuthEntry(async()=>{throw publicError})({},{}),error=>error.statusCode===404 && error.data.message==='通知不存在');
 await assert.rejects(safeAuthEntry(async()=>{throw new Error('private database detail')})({},{}),error=>error.message==='safe server error');
});
