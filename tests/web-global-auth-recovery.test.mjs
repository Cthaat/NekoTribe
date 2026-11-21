import assert from 'node:assert/strict';
import {test} from 'node:test';
import {existsSync} from 'node:fs';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';

// When present, execute the actual auto-discovered plugin. Once retired there
// is no registration to dispatch; no replacement authentication code is mocked.
const root=fileURLToPath(new URL('../',import.meta.url));
let setup;
if(existsSync(new URL('../app/plugins/error-handler.client.ts',import.meta.url))){
  const built=await build({entryPoints:[root+'app/plugins/error-handler.client.ts'],bundle:true,write:false,platform:'node',format:'esm',
    banner:{js:`const defineNuxtPlugin=fn=>fn;const clearError=()=>globalThis.__globalAuthEffects.push('clearError');`},
    plugins:[{name:'global-auth-boundary',setup(b){b.onResolve({filter:/^~\/stores\/user$/},()=>({path:'store',namespace:'stub'}));b.onLoad({filter:/.*/,namespace:'stub'},()=>({contents:`export const usePreferenceStore=()=>({async refreshAccessToken(){globalThis.__globalAuthEffects.push('refresh');}});`}));}}]});
  ({default:setup}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text+'\n//# sourceURL=global-auth-fixture.mjs\n').toString('base64')}`));
}
for(const event of ['vue:error','app:error'])for(const origin of ['unscoped','already-handled'])test(`${event} cannot start recovery for ${origin} 401`,async()=>{
  const hooks=new Map();globalThis.__globalAuthEffects=[];
  try{
    setup?.({hook:(name,fn)=>hooks.set(name,fn)});
    const error=Object.assign(Error('isolated unauthorized'),{statusCode:401,origin});
    await hooks.get(event)?.(error);assert.deepEqual(globalThis.__globalAuthEffects,[]);
  }finally{delete globalThis.__globalAuthEffects;}
});
