import assert from 'node:assert/strict';import {test} from 'node:test';import{readFileSync}from'node:fs';import{parse,compileScript}from'@vue/compiler-sfc';import{transform}from'esbuild';
async function fixture(danger=false){const{descriptor}=parse(readFileSync(new URL('../app/components/'+(danger?'SecurityPageDangerZone.vue':'SecurityPageTwoFactor.vue'),import.meta.url),'utf8'));const ast=compileScript(descriptor,{id:'security-actions'}).scriptSetupAst;const source=ast.filter(n=>n.type==='FunctionDeclaration'||(n.type==='ExpressionStatement'&&n.expression.callee?.name==='onUnmounted')).map(n=>descriptor.scriptSetup.content.slice(n.start,n.end)).join('\n');const out=await transform(`
const ref=value=>({value});export const calls=[],effects=[],loading=ref(false),actionPending=ref(false),statusFailed=ref(false),enabled=ref(false),setupPassword=ref(' x '),setupCode=ref('123456'),disablePassword=ref(' x '),disableCode=ref('code'),setup=ref({secret:'OLD',otpauthUrl:'otpauth://old'}),recoveryCodes=ref([]),password=ref(' x '),confirmation=ref(' DELETE '),pending=ref(false);
let revision=0,disposed=false;const ownerRevision=0;export const invalidate=()=>revision++;const preferenceStore={authRevision:()=>revision,isAuthCurrent:r=>r===revision,resetToDefaults(){effects.push('reset');revision++;}};
const unmounts=[];const onUnmounted=fn=>unmounts.push(fn);export const dispose=()=>unmounts.forEach(fn=>fn());const toast={success(){effects.push('success')},error(){effects.push('error')}},t=x=>x,localePath=x=>x,navigateTo=()=>effects.push('navigate');
const navigator={clipboard:{writeText:async value=>effects.push({clipboard:value})}};
let resolve,reject;const wait=new Promise((r,j)=>{resolve=r;reject=j});export const finish=(data={secret:'NEW',otpauthUrl:'otpauth://new',enabled:true,recoveryCodes:['CODE'],deleted:true,userId:42,twoFactorEnabled:true})=>resolve(data),fail=()=>reject(Error('isolated failure'));
export const statusReads=ref(0);
const v2StartTwoFactorSetup=p=>{calls.push(p);return wait},v2ConfirmTwoFactorSetup=v2StartTwoFactorSetup,v2DisableTwoFactor=v2StartTwoFactorSetup,v2DeleteMe=v2StartTwoFactorSetup,v2GetSettings=()=>{statusReads.value++;return wait};
${source}
export const run=${danger?'deleteAccount':'startSetup'};export const confirm=${danger?'deleteAccount':'confirmSetup'};export const status=${danger?'deleteAccount':'loadStatus'};
export const disable=${danger?'deleteAccount':'disableTwoFactor'};
export const copy=${danger?'deleteAccount':'copySecret'};
`,{loader:'ts',format:'esm',define:{'import.meta.client':'true'}});return import('data:text/javascript;base64,'+Buffer.from(out.code).toString('base64')+'#'+Math.random());}
for(const danger of [false,true]){
 test(`security ${danger}: direct duplicate callbacks dispatch once`,async()=>{const m=await fixture(danger);const a=m.run(),b=m.run();m.finish();await Promise.all([a,b]);assert.equal(m.calls.length,1);assert.equal(m.calls[0].password,'x');});
 test(`security ${danger}: stale success cannot publish or clear another session`,async()=>{const m=await fixture(danger);const p=m.run();m.invalidate();m.finish();await p;assert.deepEqual(m.effects,[]);if(!danger)assert.notEqual(m.setup.value?.secret,'NEW');});
 test(`security ${danger}: unmount cancels completion effects`,async()=>{const m=await fixture(danger);const p=m.run();m.dispose();m.finish();await p;assert.deepEqual(m.effects,[]);});
 test(`security ${danger}: failure preserves identity and releases retry`,async()=>{const m=await fixture(danger);const p=m.run();m.fail();await p;assert(!m.effects.includes('reset'));assert(!m.effects.includes('navigate'));assert.equal((danger?m.pending:m.actionPending).value,false);});
}
test('2FA stale confirmation cannot show recovery codes',async()=>{const m=await fixture();const p=m.confirm();m.invalidate();m.finish();await p;assert.equal(m.enabled.value,false);assert.deepEqual(m.recoveryCodes.value,[]);});
test('2FA stale initial status cannot overwrite a newer identity',async()=>{const m=await fixture();const p=m.status();m.invalidate();m.finish();await p;assert.equal(m.enabled.value,null);});

test('2FA regeneration clears the previous setup before dispatch and keeps it cleared after failure',async()=>{const m=await fixture();m.recoveryCodes.value=['OLD'];const pending=m.run();const previousSetup=m.setup.value,previousCodes=[...m.recoveryCodes.value];m.fail();await pending;assert.equal(previousSetup,null);assert.deepEqual(previousCodes,[]);assert.equal(m.setup.value,null);assert.equal(m.setupCode.value,'');});

test('2FA failed status remains unknown and blocks setup dispatch',async()=>{const m=await fixture();const pending=m.status();m.fail();await pending;await m.run();assert.equal(m.enabled.value,null);assert.equal(m.calls.length,0);});
test('2FA unknown state blocks all three direct management callbacks',async()=>{const m=await fixture();m.enabled.value=null;const work=[m.run(),m.confirm(),m.disable()];m.finish();await Promise.all(work);assert.equal(m.calls.length,0);});
test('2FA status reload ignores duplicate direct callbacks and clears old secret displays',async()=>{const m=await fixture();m.recoveryCodes.value=['OLD'];const first=m.status(),second=m.status();assert.equal(m.setup.value,null);assert.deepEqual(m.recoveryCodes.value,[]);m.finish();await Promise.all([first,second]);assert.equal(m.statusReads.value,1);assert.equal(m.enabled.value,true);assert.equal(m.loading.value,false);});
test('2FA stale copy callbacks cannot write a secret cleared by status reload',async()=>{const m=await fixture();const pending=m.status();await m.copy('OLD');m.finish();await pending;assert.deepEqual(m.effects,[]);});
