import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';
const root=fileURLToPath(new URL('../',import.meta.url));const require=createRequire(import.meta.url);
const stubs={
 './api-cache':'export const readApiResponseCache=async()=>({status:"disabled"}); export const writeApiResponseCache=async()=>{}; export const invalidateApiResponseCache=async()=>{}; export const shouldInvalidateApiResponseCache=()=>false;',
 './logging':'export const getRequestLogContext=()=>null; export const logError=()=>{}; export const logInfo=()=>{}; export const serializeLogError=()=>({});',
 './client-ip':'export const getClientIp=()=>"";',
 oracledb:'export default {OUT_FORMAT_OBJECT:4002};'
};
const bundle=await build({stdin:{contents:`export {v2Boolean} from './server/utils/v2';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'vectors',setup(builder){
 builder.onResolve({filter:/.*/},args=>{if(Object.hasOwn(stubs,args.path))return {path:args.path,namespace:'stub'};if(args.path.startsWith('~/'))return {path:path.join(root,`${args.path.slice(2)}.ts`)};if(args.path.startsWith('node:'))return {path:args.path,external:true};if(!args.path.startsWith('.')&&!path.isAbsolute(args.path))return {path:pathToFileURL(require.resolve(args.path)).href,external:true};});
 builder.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:stubs[args.path],loader:'js'}));
}}]});
const {v2Boolean}=await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`);
const fixture=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/notification-single-read.json'),'utf8'));
test('Nuxt uses shared notification read boolean cases',()=>{assert.equal(fixture.cases.length,11);for(const item of fixture.cases)assert.equal(v2Boolean(item.value),item.expected,item.id);});
