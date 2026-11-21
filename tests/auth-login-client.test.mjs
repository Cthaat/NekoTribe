import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {parse, compileScript} from '@vue/compiler-sfc';
import {transform} from 'esbuild';
import {z} from 'zod/v3';

// Exercise the actual SFC callbacks with an isolated network and UI boundary.
const {descriptor} = parse(readFileSync(new URL('../app/pages/auth/login.vue', import.meta.url), 'utf8'));
const script = compileScript(descriptor, {id:'auth-login-test'});
test('login validation allows existing short passwords and rejects empty credentials', async () => {
  const node=script.scriptSetupAst.find(node=>node.type==='VariableDeclaration'&&node.declarations.some(d=>d.id.name==='loginFormSchema'));
  const code=await transform(descriptor.scriptSetup.content.slice(node.start,node.end),{loader:'ts'});
  const schema=new Function('z','t',code.code+';return loginFormSchema;')(z,key=>key);
  assert.equal(schema.safeParse({account:' edge ',password:'x'}).success,true);
  assert.equal(schema.safeParse({account:'',password:'x'}).success,false);
  assert.equal(schema.safeParse({account:'edge',password:''}).success,false);
});
const names = ['onValidSubmit', 'handleTwoFactorSubmit'];
const callbacks = names.map(name => {
  const node = script.scriptSetupAst.find(node => node.type === 'FunctionDeclaration' && node.id.name === name);
  assert(node, `Missing actual callback ${name}`);
  return descriptor.scriptSetup.content.slice(node.start, node.end);
}).join('\n');
const built = await transform(`
export const isLoading={value:false},trustDevice={value:false},twoFactorCode={value:'123456'},twoFactorChallenge={value:{challengeId:'challenge'}};
export const calls=[],completed=[],errors=[];let request,version=0;
export function invalidate(){version++;}
const preferenceStore={authRevision:()=>version,isAuthCurrent:(expected)=>expected===version};
export function defer(){let resolve,reject;request=new Promise((a,b)=>{resolve=a;reject=b});return {resolve,reject};}
const v2Login=()=>{version++;calls.push('login');return request},v2CompleteTwoFactorLogin=()=>{version++;calls.push('challenge');return request};
const completeLogin=async()=>{completed.push(true)},isTwoFactorChallenge=()=>false,t=(x)=>x,toast={error(){errors.push(true)},info(){}};
${callbacks}
export {onValidSubmit,handleTwoFactorSubmit};
`, {loader:'ts',format:'esm'});

for(const [callback,kind] of [['onValidSubmit','login'],['handleTwoFactorSubmit','challenge']]) {
  for(const failed of [false,true])test(`${kind} stale ${failed?'failure':'success'} cannot publish state or errors`,async()=>{
    const module=await import(`data:text/javascript;base64,${Buffer.from(built.code).toString('base64')}#stale-${kind}-${failed}`);
    const request=module.defer();const pending=module[callback]({account:'edge',password:'x'});module.invalidate();
    if(failed)request.reject(Error('isolated'));else request.resolve({});await pending;
    assert.deepEqual(module.completed,[]);assert.deepEqual(module.errors,[]);
  });
  test(`${kind} callback ignores concurrent submissions and allows an explicit retry`,async()=>{
    const module=await import(`data:text/javascript;base64,${Buffer.from(built.code).toString('base64')}#${kind}`);
    const first=module.defer();
    const running=module[callback]({account:'edge',password:'password'});
    const repeated=module[callback]({account:'edge',password:'password'});
    try { assert.deepEqual(module.calls,[kind]); }
    finally { first.reject(Error('isolated failure'));await Promise.all([running,repeated]); }
    assert.equal(module.isLoading.value,false);
    const retry=module.defer();const pending=module[callback]({account:'edge',password:'password'});
    assert.deepEqual(module.calls,[kind,kind]);retry.resolve({});await pending;
  });
}
