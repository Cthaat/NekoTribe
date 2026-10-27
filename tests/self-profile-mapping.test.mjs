import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { build } from 'esbuild';

const root=fileURLToPath(new URL('../',import.meta.url));
const require=createRequire(import.meta.url);
const fixture=JSON.parse(readFileSync(new URL('../specifications/scenarios/user-self-profile.json',import.meta.url)));
const stubs={
  '#imports':'export const useRuntimeConfig=()=>({});',
  '~/server/database/readiness':'export const requireFeatureSchema=async()=>{};',
  '~/server/storage':'export const normalizeAvatarPublicUrl=v=>v||"/storage/default-avatar.png"; export const normalizeNullableStoragePublicUrl=v=>v; export const normalizeStoragePublicUrl=v=>v;',
  './api-cache':'export const readApiResponseCache=async()=>({status:"bypass"}); export const writeApiResponseCache=async()=>{}; export const invalidateApiResponseCache=async()=>{}; export const shouldInvalidateApiResponseCache=()=>false;',
  './logging':'export const getRequestLogContext=()=>null; export const logError=()=>{}; export const logInfo=()=>{}; export const serializeLogError=()=>({});',
  oracledb:'export default {OUT_FORMAT_OBJECT:4002};'
};
const compiled=await build({stdin:{contents:"export {v2GetSelfUser} from './server/models/v2';",resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'self-profile-fixtures',setup(builder){
  builder.onResolve({filter:/.*/},args=>{
    if(Object.hasOwn(stubs,args.path))return {path:args.path,namespace:'self-profile-stub'};
    if(args.path.startsWith('~/'))return {path:path.join(root,`${args.path.slice(2)}.ts`)};
    if(args.path.startsWith('node:'))return {path:args.path,external:true};
    if(!args.path.startsWith('.')&&!path.isAbsolute(args.path))return {path:pathToFileURL(require.resolve(args.path)).href,external:true};
  });
  builder.onLoad({filter:/.*/,namespace:'self-profile-stub'},args=>({contents:stubs[args.path],loader:'js'}));
}}]});
const {v2GetSelfUser}=await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

test('self profile mapper reads only the authenticated user and retains nulls and public fields',async()=>{
  let call;
  const date=new Date('2026-01-02T03:04:05.000Z');
  const row={USER_ID:42,USERNAME:'selfuser',EMAIL:'self@example.test',AVATAR_URL:null,DISPLAY_NAME:'New User',BIO:null,LOCATION:null,WEBSITE:null,PHONE:null,BIRTH_DATE:null,EMAIL_VERIFIED_AT:date,IS_VERIFIED:0,IS_ACTIVE:1,STATUS:'active',FOLLOWERS_COUNT:0,FOLLOWING_COUNT:0,POSTS_COUNT:0,LIKES_COUNT:0,ONLINE_STATUS:'online',LAST_SEEN_AT:null,CREATED_AT:date,UPDATED_AT:date,RELATION:'self'};
  const connection={async execute(sql,binds,options){call={sql:sql.replace(/\s+/g,' ').trim(),binds,options};return {rows:[row]};}};
  assert.deepEqual(await v2GetSelfUser(connection,42),fixture.profile);
  assert.match(call.sql,/FROM v_user_profile_self u WHERE u.user_id = :user_id/);
  assert.match(call.sql,/fn_get_user_relationship\(:viewer_id, u.user_id\)/);
  assert.deepEqual(call.binds,{viewer_id:42,user_id:42});
  assert.equal(call.options.outFormat,4002);
});
