import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../',import.meta.url));
const built = await build({
  stdin:{contents:`export * from './app/api/v2/ai-user-provider';`,resolveDir:root},
  bundle:true,write:false,platform:'node',format:'esm',
  plugins:[{name:'ai-provider-client',setup(builder){
    builder.onResolve({filter:/^\.\/client$/},()=>({path:'client',namespace:'fixture'}));
    builder.onLoad({filter:/^client$/,namespace:'fixture'},()=>({
      contents:`export const v2RequestData=(path,options)=>globalThis.__userProviderClient(path,options);`,loader:'js',
    }));
  }}],
});
const api = await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const base = '/api/v2/users/me/ai-provider';
const config = {preset:'default',model:'example-model',enabled:false,key_configured:true,revision:1,reconnect_required:false};
const view = {setup_available:true,presets:[{id:'default',base_url:'https://api.openai.com/v1'}],config};

test('client sends only the preset, model and optional key and confirms server receipts',async t=>{
  const signal = new AbortController().signal;
  const calls = [];
  globalThis.__userProviderClient = async (path,options)=>{
    calls.push({path,options});
    assert.equal(options.signal,signal);
    assert.equal(options.redirect,'error');
    if (options.method==='DELETE') return null;
    if (path.endsWith('/test')) return {verified:true};
    return view;
  };
  t.after(()=>delete globalThis.__userProviderClient);
  assert.deepEqual(await api.getUserProvider(signal),view);
  const body={preset:config.preset,model:config.model,enabled:config.enabled,api_key:'isolated-client-key'};
  assert.deepEqual(await api.putUserProvider(body,signal),view);
  assert.deepEqual(calls[1].options.body,body);
  await api.verifyUserProvider(signal);
  await api.removeUserProvider(signal);
  assert.deepEqual(calls.map(call=>[call.path,call.options.method]),[[base,undefined],[base,'PUT'],[base+'/test','POST'],[base,'DELETE']]);
});

test('client rejects an echoed key and a receipt for a different connection',async t=>{
  const signal = new AbortController().signal;
  t.after(()=>delete globalThis.__userProviderClient);
  globalThis.__userProviderClient = async ()=>({...view,config:{...config,api_key:'isolated-client-key'}});
  await assert.rejects(api.getUserProvider(signal),/Invalid provider settings/);
  globalThis.__userProviderClient = async ()=>view;
  await assert.rejects(api.putUserProvider({preset:'provided',model:'another-model',enabled:true},signal),/Invalid provider save receipt/);
});
