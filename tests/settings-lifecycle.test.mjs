import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync,existsSync} from 'node:fs';
import {parse,compileScript} from '@vue/compiler-sfc';
import {transform} from 'esbuild';
const expectations=Object.fromEntries(JSON.parse(readFileSync(new URL('../specifications/scenarios/user-settings-client-lifecycle.json',import.meta.url))).cases.map(c=>[c.id,c]));

async function fixture(){
 const component=new URL('../app/components/AccountSettingsPreferences.vue',import.meta.url);
 const file=existsSync(component)?component:new URL('../app/pages/account/settings.vue',import.meta.url);
 const{descriptor}=parse(readFileSync(file,'utf8'));
 const ast=compileScript(descriptor,{id:'settings-lifecycle'}).scriptSetupAst;
 const source=ast.filter(n=>n.type==='FunctionDeclaration'||(n.type==='ExpressionStatement'&&n.expression.callee?.name==='onUnmounted')).map(n=>descriptor.scriptSetup.content.slice(n.start,n.end)).join('\n');
 const out=await transform(`
 const ref=value=>({value});
 export const base={userId:42,loginAlerts:true,profileVisibility:'public',showOnlineStatus:true,allowDmFromStrangers:false,pushNotificationEnabled:true,emailNotificationEnabled:true};
 export const loading=ref(false),saving=ref(false),snapshot=ref({...base}),statusFailed=ref(false),saveUncertain=ref(false),loginAlerts=ref(true),profileVisibility=ref('public'),showOnlineStatus=ref(true),allowDmFromStrangers=ref(false),pushNotificationEnabled=ref(true),emailNotificationEnabled=ref(true),effects=[],calls=[],reads=[];
 let disposed=false;export const queue={revision:0,isIdentityChanging:false};const ownerRevision=0;
 const unmounts=[];const onUnmounted=fn=>unmounts.push(fn);export const dispose=()=>unmounts.forEach(fn=>fn());const t=x=>x,toast={success:()=>effects.push('success'),error:()=>effects.push('error')};
 const pending=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return{promise,resolve,reject};};
 const v2GetSettings=()=>{const p=pending();reads.push(p);return p.promise;},v2PatchSettings=body=>{const p=pending();calls.push({body,...p});return p.promise;};
 ${source}
 export {loadSettings,saveSettings};
 `,{loader:'ts',format:'esm'});
 return import('data:text/javascript;base64,'+Buffer.from(out.code).toString('base64')+'#'+Math.random());
}
test('settings dispatches only changed fields and ignores duplicate save/reload while pending',async()=>{
 const m=await fixture();m.loginAlerts.value=false;const a=m.saveSettings(),b=m.saveSettings(),c=m.loadSettings();assert.equal(m.calls.length,expectations['duplicate-save'].expectedWrites);assert.equal(m.reads.length,0);assert.deepEqual(m.calls[0].body,{loginAlerts:false});m.calls[0].resolve({...m.base,loginAlerts:false});await Promise.all([a,b,c]);
});
test('retained direct callbacks cannot dispatch after identity intent begins',async()=>{
 const m=await fixture();m.loginAlerts.value=false;m.queue.revision++;await m.saveSettings();await m.loadSettings();assert.equal(m.calls.length,expectations['stale-owner'].expectedWrites);assert.equal(m.reads.length,0);
});
test('failed first read blocks direct saving of defaults',async()=>{
 const m=await fixture();m.snapshot.value=null;const p=m.loadSettings();m.reads[0].reject(Error('isolated'));await p;m.loginAlerts.value=false;const attempt=m.saveSettings();assert.equal(m.calls.length,expectations['initial-read-failed'].expectedWrites);await attempt;assert.equal(m.statusFailed.value,true);
});
test('saving applies the returned server snapshot rather than preserving unsent local values',async()=>{
 const m=await fixture();m.loginAlerts.value=false;const p=m.saveSettings();m.calls[0].resolve({...m.base,loginAlerts:false,showOnlineStatus:false});await p;assert.equal(m.showOnlineStatus.value,false);assert.equal(m.snapshot.value.showOnlineStatus,false);assert.deepEqual(m.effects,['success']);
});
test('uncertain save never automatically replays and blocks another patch until explicit read',async()=>{
 const m=await fixture();m.loginAlerts.value=false;const p=m.saveSettings();m.calls[0].reject(Error('could-have-committed'));await p;const attempt=m.saveSettings();assert.equal(m.calls.length,expectations['uncertain-save'].expectedWrites);await attempt;assert.equal(m.reads.length,expectations['uncertain-save'].expectedAutomaticReads);assert.equal(m.saveUncertain.value,true);assert.equal(m.snapshot.value,null);const reload=m.loadSettings();m.reads[0].resolve({...m.base,loginAlerts:false});await reload;assert.equal(m.saveUncertain.value,false);
});
for(const operation of ['loadSettings','saveSettings'])for(const invalidation of ['identity','unmount'])test(operation+' ignores '+invalidation+' completion',async()=>{
 const m=await fixture();if(operation==='saveSettings')m.loginAlerts.value=false;const work=m[operation]();if(invalidation==='identity')m.queue.revision++;else m.dispose();const pending=operation==='saveSettings'?m.calls[0]:m.reads[0];pending.resolve({...m.base,profileVisibility:'private'});await work;assert.notEqual(m.profileVisibility.value,'private');assert.deepEqual(m.effects,[]);
});
test('legacy unknown privacy is not silently normalized or included with unrelated changes',async()=>{
 const m=await fixture();m.snapshot.value.profileVisibility='legacy';m.profileVisibility.value='legacy';m.loginAlerts.value=false;const work=m.saveSettings();assert.deepEqual(m.calls[0].body,{loginAlerts:false});m.calls[0].resolve({...m.base,profileVisibility:'legacy',loginAlerts:false});await work;assert.equal(m.profileVisibility.value,'legacy');
});
test('no-op and newly invalid privacy do not dispatch PATCH',async()=>{
 const m=await fixture();let count=m.calls.length;const a=m.saveSettings();assert.equal(m.calls.length,count);await a;m.profileVisibility.value='followers';const b=m.saveSettings();assert.equal(m.calls.length,count);await b;
});
