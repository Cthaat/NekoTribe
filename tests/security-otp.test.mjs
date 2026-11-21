import assert from 'node:assert/strict';
import {test, afterEach} from 'node:test';
import {readFileSync} from 'node:fs';
import {parse, compileScript} from '@vue/compiler-sfc';
import {transform} from 'esbuild';
import * as vue from 'vue';
import {z} from 'zod/v3';
globalThis.__securityOtpZod=z;

globalThis.__securityOtpVue = vue;
const cleanups = [];
afterEach(() => { for (const dispose of cleanups.splice(0)) dispose(); });

async function fixture(kind = 'Email') {
  const {descriptor} = parse(readFileSync(new URL(`../app/components/SecurityPage${kind}.vue`, import.meta.url), 'utf8'));
  const ast = compileScript(descriptor, {id:'security-otp'}).scriptSetupAst;
  const selected = ast.filter(n => n.type === 'FunctionDeclaration' ||
    (n.type === 'VariableDeclaration' && n.declarations.some(d => d.id.name === 'onSubmit')) ||
    (n.type === 'ExpressionStatement' && ['watch','onUnmounted'].includes(n.expression.callee?.name)));
  const source = selected.map(n => descriptor.scriptSetup.content.slice(n.start,n.end)).join('\n');
  const built = await transform(`
const {ref, reactive} = globalThis.__securityOtpVue, stops=[], unmounts=[];
const z=globalThis.__securityOtpZod;
const watch=(...args)=>stops.push(globalThis.__securityOtpVue.watch(...args)), onUnmounted=fn=>unmounts.push(fn);
export const dispose=()=>{for(const fn of unmounts)fn();for(const stop of stops)stop();};
export const calls=[],timers=[],clearedTimers=[],toasts=[],values=reactive({email:'new@example.test',newPassword:'synthetic'});
let onLogout=()=>{};
export const preferenceStore={preferences:reactive({user:{email:'old@example.test'}}),authRevision:()=>revision,isAuthCurrent:r=>r===revision,async logoutCurrentSession(r){if(r!==revision)return null;calls.push({type:'logout'});const clearedRevision=++revision;onLogout();return{revision:clearedRevision,ok:true};}};
let revision=0;const ownerRevision=0;export const invalidate=()=>revision++;
export const verificationId=ref(''),verificationAccount=ref(''),verificationAuthRevision=ref(null),value=ref([]),isCaptchaSending=ref(false),isLoading=ref(false),countdown=ref(60);
let timer=null,otpRequestVersion=0,otpDisposed=false;
const sends=[],changes=[];
export const finishSend=(i=0,account=calls.filter(c=>c.type==='send')[i].payload.account)=>sends[i].resolve({account,verificationId:'otp-'+i}),failSend=(i=0,error=Error('isolated send failure'))=>sends[i].reject(error);
export const failAllSends=()=>sends.forEach(s=>s.reject(Error('isolated send failure')));
export const finishChange=()=>changes[0].resolve(),failChange=()=>changes[0].reject(Error('isolated change failure'));
const v2CreateOtp=payload=>{calls.push({type:'send',payload});return new Promise((resolve,reject)=>sends.push({resolve,reject}));},v2ChangeEmail=payload=>{calls.push({type:'change',payload});return new Promise((resolve,reject)=>changes.push({resolve,reject}));},v2PasswordReset=v2ChangeEmail;
const props={},resetForm=({values:next})=>Object.assign(values,next),form={values,resetForm},handleSubmit=fn=>fn,toast={success(){toasts.push('success');},error(){toasts.push('error');}},t=x=>x,localePath=x=>x,navigateTo=()=>calls.push({type:'navigate'});
export const bindParent=fn=>props.onSessionCleared=fn,disposeDuringLogout=fn=>onLogout=fn;
const setInterval=fn=>{timers.push(fn);return timers.length;},clearInterval=id=>clearedTimers.push(id),setTimeout=fn=>{timers.push(fn);};
let now=1000;
const Date={now:()=>now};
export const advanceCooldown=seconds=>{now+=seconds*1000;timers.at(-1)?.();};
${readFileSync(new URL('../app/utils/otpRetryAfter.ts',import.meta.url),'utf8')}
${source}
export {sendCaptcha,onSubmit};
`, {loader:'ts',format:'esm'});
  const m = await import(`data:text/javascript;base64,${Buffer.from(built.code).toString('base64')}#${Math.random()}`);
  cleanups.push(m.dispose); return m;
}

for(const c of JSON.parse(readFileSync(new URL('../specifications/scenarios/auth-account-input.json',import.meta.url))).emailCases.filter(c=>typeof c.raw==='string'&&!c.valid))test(`change-email refuses invalid email before dispatch: ${c.id}`,async()=>{
 const m=await fixture();m.values.email=c.raw;await m.sendCaptcha();assert(!m.calls.some(c=>c.type==='send'));
});

for(const kind of ['Email','PasswordForm']){
 test(`${kind}: expired owner cannot start another OTP request`,async()=>{const m=await fixture(kind);m.invalidate();await m.sendCaptcha();assert.equal(m.calls.length,0);});
 test(`${kind}: parent receives own logout receipt after the credential form unmounts`,async()=>{
  const m=await fixture(kind),receipts=[];m.bindParent(r=>receipts.push(r));m.disposeDuringLogout(m.dispose);
  const send=m.sendCaptcha();m.finishSend();await send;m.value.value=['123456'];const pending=m.onSubmit(m.values);m.finishChange();await pending;
  assert.deepEqual(receipts,[{revision:1,ok:true}]);assert.equal(m.verificationId.value,'');assert.equal(kind==='PasswordForm'?m.values.newPassword:m.values.email,'');
 });
}
test('change-email sends the OTP to the new email required by the backend', async () => {
  const m=await fixture(); const pending=m.sendCaptcha(); m.finishSend(); await pending;
  assert.equal(m.calls[0].payload.account,'new@example.test');
});
for (const kind of ['Email','PasswordForm']) {
  test(`${kind}: throttled resend retains the current session's issued code`,async()=>{
    const m=await fixture(kind);
    const initial=m.sendCaptcha();m.finishSend();await initial;
    m.advanceCooldown(60);
    m.value.value=['123456'];
    const resend=m.sendCaptcha();
    m.failSend(1,{response:{status:429,headers:new Headers({'Retry-After':'invalid'})}});
    await resend;
    assert.equal(m.countdown.value,60);
    assert.equal(m.verificationId.value,'otp-0');
    assert.deepEqual(m.value.value,['123456']);
    const submit=m.onSubmit(m.values);
    assert.equal(m.calls.find(c=>c.type==='change').payload.verificationId,'otp-0');
    m.finishChange();await submit;
  });
  test(`${kind}: repeated callback sends once and failure releases retry`,async()=>{
    const m=await fixture(kind); const a=m.sendCaptcha(),b=m.sendCaptcha(); m.failAllSends(); await Promise.all([a,b]);
    assert.equal(m.calls.length,1); assert.equal(m.isCaptchaSending.value,false); assert.equal(m.verificationId.value,'');
    const retry=m.sendCaptcha(); m.finishSend(1); await retry; assert.equal(m.verificationId.value,'otp-1');
  });
  test(`${kind}: account ABA invalidates a late response and entered OTP`,async()=>{
    const m=await fixture(kind); const pending=m.sendCaptcha();
    if(kind==='Email'){m.values.email='other@example.test';m.values.email='new@example.test';}
    else {m.preferenceStore.preferences.user.email='other@example.test';m.preferenceStore.preferences.user.email='old@example.test';}
    m.value.value=['123456']; m.finishSend(); await pending;
    assert.equal(m.verificationId.value,''); assert.equal(m.timers.length,0);
  });
  test(`${kind}: a superseded session cannot publish a late OTP`,async()=>{
    const m=await fixture(kind); const pending=m.sendCaptcha(); m.invalidate(); m.finishSend(); await pending;
    assert.equal(m.verificationId.value,''); assert.equal(m.timers.length,0); assert.equal(m.toasts.length,0);
  });
  test(`${kind}: unmount discards OTP and creates no timer`,async()=>{
    const m=await fixture(kind); const pending=m.sendCaptcha(); m.dispose();m.finishSend();await pending;
    assert.equal(m.verificationId.value,'');assert.equal(m.timers.length,0);assert.equal(m.toasts.length,0);
  });
  test(`${kind}: an OTP from a previous session cannot submit`,async()=>{
    const m=await fixture(kind);const sent=m.sendCaptcha();m.finishSend();await sent;m.value.value=['123456'];m.invalidate();
    const pending=m.onSubmit(m.values);
    // Allow a broken implementation's request to settle, then inspect dispatch.
    if(m.calls.some(c=>c.type==='change'))m.finishChange();await pending;
    assert(!m.calls.some(c=>c.type==='change'));assert(!m.calls.some(c=>c.type==='logout'));
  });
  test(`${kind}: mutation completion after unmount cannot logout`,async()=>{
    const m=await fixture(kind);const sent=m.sendCaptcha();m.finishSend();await sent;m.value.value=['123456'];
    const pending=m.onSubmit(m.values);m.dispose();m.finishChange();await pending;
    assert(!m.calls.some(c=>c.type==='logout'));
  });
  test(`${kind}: late old failure cannot release a newer send or show an error`,async()=>{
    const m=await fixture(kind),old=m.sendCaptcha();
    if(kind==='Email')m.values.email='other@example.test';
    else m.preferenceStore.preferences.user.email='other@example.test';
    const current=m.sendCaptcha();m.failSend(0);await old;
    assert.equal(m.isCaptchaSending.value,true);assert.equal(m.toasts.length,0);
    m.finishSend(1);await current;assert.equal(m.verificationId.value,'otp-1');
  });
  test(`${kind}: a response for a different account is rejected`,async()=>{
    const m=await fixture(kind),pending=m.sendCaptcha();m.finishSend(0,'wrong@example.test');await pending;
    assert.equal(m.verificationId.value,'');assert.equal(m.isCaptchaSending.value,false);assert.deepEqual(m.toasts,['error']);assert.equal(m.timers.length,0);
  });
  test(`${kind}: active countdown is cleared on unmount and cannot restart`,async()=>{
    const m=await fixture(kind),pending=m.sendCaptcha();m.finishSend();await pending;
    m.dispose();const before=m.countdown.value;m.timers[0]();
    assert.equal(m.countdown.value,before);assert(m.clearedTimers.includes(1));assert.equal(m.verificationId.value,'');
  });
  test(`${kind}: current mutation uses the captured payload and logs out once`,async()=>{
    const m=await fixture(kind),sent=m.sendCaptcha();m.finishSend();await sent;m.value.value=['123456'];
    const pending=m.onSubmit(m.values);m.value.value=['654321'];m.values.newPassword='changed';m.finishChange();await pending;
    const payload=m.calls.find(c=>c.type==='change').payload;
    assert.equal(payload.code,'123456');assert.equal(payload.verificationId,'otp-0');
    if(kind==='PasswordForm')assert.equal(payload.newPassword,'synthetic');
    else assert.equal(payload.newEmail,'new@example.test');
    assert.equal(m.calls.filter(c=>c.type==='logout').length,1);
  });
  test(`${kind}: failed mutation preserves the session and releases submission`,async()=>{
    const m=await fixture(kind),sent=m.sendCaptcha();m.finishSend();await sent;m.value.value=['123456'];
    const pending=m.onSubmit(m.values);m.failChange();await pending;
    assert(!m.calls.some(c=>c.type==='logout'));assert.equal(m.isLoading.value,false);
  });
}
