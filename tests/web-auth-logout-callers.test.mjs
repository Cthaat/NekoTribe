import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {parse,compileScript} from '@vue/compiler-sfc';
import {transform} from 'esbuild';

async function callback(file,nav=false){
  const {descriptor}=parse(readFileSync(new URL('../app/'+file,import.meta.url),'utf8'));
  const ast=compileScript(descriptor,{id:'logout-caller'}).scriptSetupAst;
  const node=nav?ast.find(n=>n.type==='FunctionDeclaration'&&n.id.name==='handleLogout'):ast.find(n=>n.type==='VariableDeclaration'&&n.declarations.some(d=>d.id.name==='onSubmit'));
  const body=descriptor.scriptSetup.content.slice(node.start,node.end);
  const built=await transform(`
let version=0,resolveCredential,rejectCredential,resolveLogout,logoutFailure=false;
const credential=new Promise((r,j)=>{resolveCredential=r;rejectCredential=j;}),logout=new Promise(r=>{resolveLogout=r});
export const effects=[],timers=[],isLoading={value:false};
export function invalidate(){version++;}export function finishCredential(){resolveCredential();}export function finishLogout(){resolveLogout();}
export function failLogout(){logoutFailure=true;resolveLogout();}
export function failCredential(){rejectCredential(Error('isolated credential failure'));}
const preferenceStore={preferences:{user:{email:'edge@example.test'}},authRevision:()=>version,isAuthCurrent:r=>r===version,resetToDefaults(){effects.push('reset');version++;},async logoutCurrentSession(expected=version){if(expected!==version)return null;const revision=++version;effects.push('logout');await logout;if(revision!==version)return null;this.resetToDefaults();return logoutFailure?{revision:version,ok:false,error:null}:{revision:version,ok:true};}};
const props={},ownerRevision=0,verificationId={value:'otp'},verificationAccount={value:'edge@example.test'},verificationAuthRevision={value:0},value={value:['123456']},otpDisposed=false,otpRequestVersion=0,isOtpCurrent=()=>true,t=x=>x,localePath=x=>x;
const toast=Object.assign(()=>{}, {success(){},error(){effects.push('error');}}),navigateTo=()=>effects.push('navigate'),setTimeout=fn=>timers.push(fn),handleSubmit=fn=>fn;
const v2PasswordReset=()=>credential,v2ChangeEmail=()=>credential,v2LogoutCurrent=()=>{effects.push('legacy-logout');return logout;};
${body}
export const run=${nav?'handleLogout':'onSubmit'};
`,{loader:'ts',format:'esm'});
  return import(`data:text/javascript;base64,${Buffer.from(built.code).toString('base64')}#${file}-${Math.random()}`);
}
for(const file of ['pages/auth/forgot-password.vue','components/SecurityPagePasswordForm.vue','components/SecurityPageEmail.vue']) {
  test(`${file}: a superseded credential request cannot start logout`,async()=>{
    const m=await callback(file);const pending=m.run({email:'edge@example.test',newPassword:'synthetic'});m.invalidate();m.finishCredential();m.finishLogout();await pending;assert.deepEqual(m.effects,[]);
  });
  test(`${file}: delayed logout navigation checks the current session`,async()=>{
    const m=await callback(file);const pending=m.run({email:'edge@example.test',newPassword:'synthetic'});m.finishCredential();m.finishLogout();await pending;assert.equal(m.timers.length,1);m.invalidate();m.timers[0]();assert(!m.effects.includes('navigate'));
  });
}
test('NavUser: a superseded logout cannot navigate away from a new session',async()=>{
  const m=await callback('components/NavUser.vue',true);const pending=m.run();m.invalidate();m.finishLogout();await pending;assert(!m.effects.includes('navigate'));
});
for(const file of ['components/SecurityPagePasswordForm.vue','components/SecurityPageEmail.vue'])test(`${file}: failed mutation must not initiate logout`,async()=>{
  const m=await callback(file);const pending=m.run({email:'edge@example.test',newPassword:'synthetic'});m.failCredential();m.finishLogout();await pending;assert(!m.effects.includes('logout'));assert(!m.effects.includes('navigate'));assert.equal(m.timers.length,0);
});

for(const file of ['pages/auth/forgot-password.vue','components/SecurityPagePasswordForm.vue','components/SecurityPageEmail.vue','components/NavUser.vue']) test(`${file}: falsy logout errors cannot become successful navigation`,async()=>{
  const m=await callback(file,file==='components/NavUser.vue');
  const pending=m.run({email:'edge@example.test',newPassword:'synthetic'});
  m.finishCredential();m.failLogout();await pending;
  assert(m.effects.includes('error'));assert(!m.effects.includes('navigate'));assert.equal(m.timers.length,0);
});
