import assert from 'node:assert/strict';
import {test,afterEach} from 'node:test';
import {readFileSync} from 'node:fs';
import {parse,compileScript} from '@vue/compiler-sfc';
import {transform} from 'esbuild';
import * as vue from 'vue';
import {z} from 'zod/v3';
globalThis.__publicAccountZod=z;
globalThis.__publicAccountVue=vue;
const cleanups=[];
afterEach(()=>{for(const cleanup of cleanups.splice(0))cleanup();});

async function fixture(kind='sign-up'){
  const {descriptor}=parse(readFileSync(new URL(`../app/pages/auth/${kind}.vue`,import.meta.url),'utf8'));
  const ast=compileScript(descriptor,{id:'public-account'}).scriptSetupAst;
  const selected=ast.filter(n=>(n.type==='FunctionDeclaration'&&['sendCaptcha','onValidSubmit','resetVerification','isOtpCurrent','beginOtpCooldown'].includes(n.id.name))||(kind==='forgot-password'&&n.type==='VariableDeclaration'&&n.declarations.some(d=>d.id.name==='onSubmit'))||(n.type==='ExpressionStatement'&&['watch','onUnmounted'].includes(n.expression.callee?.name)&&descriptor.scriptSetup.content.slice(n.start,n.end).includes('resetVerification')));
  const source=selected.map(n=>descriptor.scriptSetup.content.slice(n.start,n.end)).join('\n');
  const built=await transform(`
const {ref,reactive}=globalThis.__publicAccountVue,stops=[],unmounts=[];
const z=globalThis.__publicAccountZod;
const watch=(...args)=>stops.push(globalThis.__publicAccountVue.watch(...args)),onUnmounted=fn=>unmounts.push(fn);
export const dispose=()=>{for(const fn of unmounts)fn();for(const stop of stops)stop();};
export const calls=[],timers=[],values=reactive({email:'old@example.test',username:'old',displayName:'Old',password:'synthetic',confirmPassword:'synthetic',phone:'',location:'',bio:'',agreeToTerms:true});
export const isLoading=ref(false),isCaptchaSending=ref(false),countdown=ref(60),verificationId=ref('otp-old'),verificationAccount=ref('old@example.test'),value=ref(['123456']),email=ref('old@example.test');
let timer=null,otpRequestVersion=0,otpDisposed=false,resolveSend,rejectSend,resolveVerify,rejectReset;
const sending=new Promise((r,j)=>{resolveSend=r;rejectSend=j;}),verifying=new Promise(r=>{resolveVerify=r}),resetting=new Promise((r,j)=>{rejectReset=j});resetting.catch(()=>{});
export const finishSend=()=>resolveSend({account:'old@example.test',verificationId:'late-otp'}),failSend=(error=Error('isolated send failed'))=>rejectSend(error),finishVerify=(verified=true)=>resolveVerify({account:'old@example.test',verified}),failReset=()=>rejectReset(Error('isolated reset failed'));
const form={values,validateField:async()=>({valid:true,errors:[]})},handleSubmit=fn=>fn;
const preferenceStore={authRevision:()=>0,isAuthCurrent:()=>true,logoutCurrentSession:async()=>{calls.push({type:'logout'});return {revision:0,ok:true};}};
const v2CreateOtp=payload=>{calls.push({type:'send',payload});return sending;},v2VerifyOtp=payload=>{calls.push({type:'verify',payload});return verifying;},v2Register=async payload=>{calls.push({type:'register',payload});},v2PasswordReset=payload=>{calls.push({type:'reset',payload});return resetting;};
const toast=Object.assign(()=>{},{success(){},error(){}}),t=x=>x,navigateTo=()=>{},localePath=x=>x,setTimeout=()=>{},setInterval=fn=>{timers.push(fn);return timers.length;},clearInterval=()=>{};
let now=1000;
const Date={now:()=>now};
export const advanceCooldown=seconds=>{now+=seconds*1000;timers.at(-1)?.();};
${readFileSync(new URL('../app/utils/otpRetryAfter.ts',import.meta.url),'utf8')}
${source}
export const submit=${kind==='sign-up'?'onValidSubmit':'onSubmit'};
export {sendCaptcha};
`,{loader:'ts',format:'esm'});
  const module=await import(`data:text/javascript;base64,${Buffer.from(built.code+'\n//# sourceURL=public-account-fixture.mjs\n').toString('base64')}#${Math.random()}`);cleanups.push(module.dispose);return module;
}
for(const c of JSON.parse(readFileSync(new URL('../specifications/scenarios/auth-account-input.json',import.meta.url))).emailCases.filter(c=>typeof c.raw==='string'&&!c.valid))test(`forgot-password refuses invalid email before dispatch: ${c.id}`,async()=>{
 const m=await fixture('forgot-password');m.email.value=c.raw;await m.sendCaptcha();assert(!m.calls.some(c=>c.type==='send'));
});
test('registration snapshots verified identity and payload across an await',async()=>{
  const m=await fixture();const pending=m.submit(m.values);m.values.username='new';m.verificationId.value='otp-new';m.finishVerify();await pending;
  const registered=m.calls.find(c=>c.type==='register');assert.equal(registered.payload.email,'old@example.test');assert.equal(registered.payload.username,'old');assert.equal(registered.payload.verificationId,'otp-old');
});
test('registration ignores repeated submit callbacks during OTP verification',async()=>{
  const m=await fixture();const first=m.submit(m.values),second=m.submit(m.values);m.finishVerify();await Promise.all([first,second]);assert.equal(m.calls.filter(c=>c.type==='verify').length,1);assert.equal(m.calls.filter(c=>c.type==='register').length,1);
});
for(const kind of ['sign-up','forgot-password'])test(`${kind}: repeated send callbacks create one request and old account responses are discarded`,async()=>{
  const m=await fixture(kind);const first=m.sendCaptcha(),second=m.sendCaptcha();await Promise.resolve();m.values.email='new@example.test';m.email.value='new@example.test';m.finishSend();await Promise.all([first,second]);assert.equal(m.calls.filter(c=>c.type==='send').length,1);assert.notEqual(m.verificationId.value,'late-otp');
});
test('failed password reset does not invoke logout and duplicate submit is ignored',async()=>{
  const m=await fixture('forgot-password');const first=m.submit({...m.values,newPassword:'synthetic'}),second=m.submit({...m.values,newPassword:'synthetic'});m.failReset();await Promise.all([first,second]);assert.equal(m.calls.filter(c=>c.type==='reset').length,1);assert.equal(m.calls.filter(c=>c.type==='logout').length,0);
});
test('registration cannot advance after false verification',async()=>{
  const m=await fixture();const pending=m.submit(m.values);m.finishVerify(false);await pending;assert(!m.calls.some(c=>c.type==='register'));
});
for(const kind of ['sign-up','forgot-password']){
  test(`${kind}: a throttled resend keeps the previous code and waits for Retry-After`,async()=>{
    const m=await fixture(kind);
    const pending=m.sendCaptcha();
    m.failSend({response:{status:429,headers:new Headers({'Retry-After':'42'})}});
    await pending;
    assert.equal(m.verificationId.value,'otp-old');
    assert.deepEqual(m.value.value,['123456']);
    assert.equal(m.countdown.value,42);
    m.advanceCooldown(41);
    await m.sendCaptcha();
    assert.equal(m.calls.filter(c=>c.type==='send').length,1);
    m.advanceCooldown(1);
    assert.equal(m.isCaptchaSending.value,false);
  });
  test(`${kind}: account ABA and unmount invalidate old OTP responses`,async()=>{
    const m=await fixture(kind);const pending=m.sendCaptcha();await Promise.resolve();m.values.email='new@example.test';m.email.value='new@example.test';m.values.email='old@example.test';m.email.value='old@example.test';m.finishSend();await pending;assert.equal(m.verificationId.value,'');
    const unmounted=await fixture(kind);const late=unmounted.sendCaptcha();await Promise.resolve();unmounted.dispose();unmounted.finishSend();await late;assert.equal(unmounted.verificationId.value,'');assert.equal(unmounted.timers.length,0);
  });
  test(`${kind}: send failure releases the button and clears old verification`,async()=>{
    const m=await fixture(kind);const pending=m.sendCaptcha();m.failSend();await pending;assert.equal(m.isCaptchaSending.value,false);assert.equal(m.verificationId.value,'');
  });
}
