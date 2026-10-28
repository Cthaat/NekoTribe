import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createRequire} from 'node:module';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';
const root=fileURLToPath(new URL('../',import.meta.url));
const require=createRequire(import.meta.url);
const stubs={
  '~/server/services/v2/notifications':'export const v2SetNotificationReadStatus=async(_event,_db,id)=>id;',
  '~/server/utils/auth-entry-errors':'export const safeAuthEntry=f=>f;',
  '~/server/utils/v2':'export const defineV2Handler=f=>f; export const v2RouterNumber=(event,key)=>{const n=Number(event.context.params[key]);if(!Number.isFinite(n)||n<=0)throw new Error("bad id");return n}; export const v2BadRequest=()=>{throw new Error("bad id")};'
};
const bundle=await build({entryPoints:[path.join(root,'server/api/v2/notifications/[id]/read-status.put.ts')],bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'id-stubs',setup(builder){
  builder.onResolve({filter:/.*/},args=>{if(Object.hasOwn(stubs,args.path))return {path:args.path,namespace:'stub'};if(args.path.startsWith('~/'))return {path:path.join(root,`${args.path.slice(2)}.ts`)};if(args.path.startsWith('node:'))return {path:args.path,external:true};if(!args.path.startsWith('.')&&!path.isAbsolute(args.path))return {path:pathToFileURL(require.resolve(args.path)).href,external:true};});
  builder.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:stubs[args.path],loader:'js'}));
}}]});
const {default:handler}=await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`);
test('notification read route accepts only canonical safe positive identifiers',async()=>{
  const event=id=>({context:{params:{id}},node:{res:{setHeader(){}}}});
  for(const id of ['1','9007199254740991'])assert.equal(await handler(event(id),{}),Number(id));
  for(const id of ['0','01','1.5','-1','9007199254740992','1e2'])await assert.rejects(handler(event(id),{}),error=>error.statusCode===400,id);
});
