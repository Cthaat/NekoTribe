import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {parse,compileScript,compileTemplate} from '@vue/compiler-sfc';
import {build} from 'esbuild';
import * as vue from 'vue';
globalThis.__gateVue=vue;
const root=fileURLToPath(new URL('../',import.meta.url));
const {descriptor}=parse(readFileSync(root+'app/components/SecurityPage.vue','utf8'));
const script=compileScript(descriptor,{id:'security-session-gate'});
const template=compileTemplate({source:descriptor.template.content,id:'security-session-gate',filename:'SecurityPage.vue',compilerOptions:{bindingMetadata:script.bindings}});
if(template.errors.length)throw Error(JSON.stringify(template.errors));
const source=script.content.replace('export default','const component =')+'\n'+template.code.replace('export function render','function render')+'\ncomponent.render=render;export default component;export {authQueueFor} from "./app/services/auth-request-queue";';
const built=await build({stdin:{contents:source,resolveDir:root,loader:'ts'},alias:{'@':root+'app'},bundle:true,write:false,platform:'node',format:'esm',banner:{js:'const useAppLocale=()=>({t:x=>x}),useLocalePath=()=>x=>x,navigateTo=path=>{globalThis.__gate.effects.push(path);return globalThis.__gate.navigation?.();};'},plugins:[{name:'gate-boundaries',setup(b){
 b.onResolve({filter:/^(vue|#app|lucide-vue-next|vue-sonner|@\/stores\/user|@\/components\/ui\/button|@\/components\/SecurityPage.*\.vue)$/},args=>({path:args.path,namespace:'stub'}));
 b.onLoad({filter:/.*/,namespace:'stub'},({path})=>({contents:
  path==='vue'?Object.keys(vue).filter(k=>/^[a-zA-Z_$][\w$]*$/.test(k)).map(k=>'export const '+k+'=globalThis.__gateVue.'+k+';').join('\n'):
  path==='#app'?'export const useNuxtApp=()=>globalThis.__gate.owner;':
  path==='@/stores/user'?'export const usePreferenceStore=()=>({isAuthCurrent:r=>globalThis.__gate.queue.revision===r});':
  path==='vue-sonner'?'export const toast={error:()=>globalThis.__gate.effects.push("error")};':
  path==='lucide-vue-next'?'export const KeyRound={},Mail={},ShieldCheck={};':
  path==='@/components/ui/button'?'export const Button={inheritAttrs:false,setup(props,{attrs,slots}){return()=>globalThis.__gateVue.h("button",attrs,slots.default?.());}};':
  'export default {props:["onSessionCleared"],setup(props){const v=globalThis.__gateVue,g=globalThis.__gate;g.mounts++;if(props.onSessionCleared)g.finish=props.onSessionCleared;v.onUnmounted(()=>g.unmounts++);return()=>v.h("section",{"data-secret-form":true},"synthetic-private");}};'
 }));
}}]});
const api=await import('data:text/javascript;base64,'+Buffer.from(built.outputFiles[0].text).toString('base64'));
const renderer=vue.createRenderer({
 createElement:type=>({type,children:[],props:{}}),createText:text=>({text}),createComment:text=>({comment:text}),
 setText:(n,text)=>{n.text=text;},setElementText:(n,text)=>{n.text=text;n.children=[];},patchProp:(n,key,old,value)=>{n.props[key]=value;},
 parentNode:n=>n.parent,nextSibling:n=>n.parent?.children[n.parent.children.indexOf(n)+1],
 insert(n,p,anchor){if(n.parent)this.remove(n);n.parent=p;const i=anchor?p.children.indexOf(anchor):-1;if(i<0)p.children.push(n);else p.children.splice(i,0,n);},
 remove(n){if(n.parent){const siblings=n.parent.children,i=siblings.indexOf(n);if(i>=0)siblings.splice(i,1);n.parent=null;}}
});
async function fixture(run){const owner={runWithContext:fn=>fn()},queue=api.authQueueFor(owner),state={owner,queue,mounts:0,unmounts:0,effects:[]};globalThis.__gate=state;const rootNode={children:[]},app=renderer.createApp(api.default);app.mount(rootNode);let active=true;const unmount=()=>{if(active){active=false;app.unmount();}};
 const all=()=>{const out=[];const walk=n=>{out.push(n);for(const c of n.children??[])walk(c);};walk(rootNode);return out;};
 try{await run({...state,state,queue,all,unmount});}finally{unmount();delete globalThis.__gate;}
}
test('actual security template unmounts every private form on same-account identity revision change',()=>fixture(async({state,queue,all})=>{
 assert.equal(state.mounts,4);queue.beginIdentityChange();await vue.nextTick();assert.equal(state.unmounts,4);assert.equal(all().filter(n=>n.props?.['data-secret-form']).length,0);
 const button=all().find(n=>n.type==='button');button.props.onClick();await vue.nextTick();assert.equal(state.mounts,8);
}));
test('queued identity work blocks reopening until its response settles',()=>fixture(async({state,queue,all})=>{
 let finish;const pending=queue.runIdentityChange(()=>new Promise(r=>{finish=r;}));await vue.nextTick();
 const button=all().find(n=>n.type==='button');assert.equal(button.props.disabled,true);button.props.onClick();await vue.nextTick();assert.equal(state.mounts,4);
 finish();await pending;await vue.nextTick();const current=all().find(n=>n.type==='button');assert.equal(current.props.disabled,false);current.props.onClick();await vue.nextTick();assert.equal(state.mounts,8);
}));
test('ordinary refresh and another SSR owner preserve current private forms',()=>fixture(async({state,queue})=>{
 await queue.run(async()=>{});api.authQueueFor({}).beginIdentityChange();await vue.nextTick();assert.equal(state.unmounts,0);
}));
test('parent owns current session-clear navigation after child unmount, but ignores stale or disposed callbacks',()=>fixture(async({state,queue,unmount})=>{
 const finish=state.finish;queue.beginIdentityChange();await vue.nextTick();finish({revision:0,ok:true});assert.deepEqual(state.effects,[]);
 finish({revision:queue.revision,ok:true});assert.deepEqual(state.effects,['/auth/login']);unmount();finish({revision:queue.revision,ok:true});assert.equal(state.effects.length,1);
}));
test('parent handles a current navigation failure without an unhandled rejection',()=>fixture(async({state,queue})=>{
 state.navigation=()=>Promise.reject(Error('isolated route failure'));
 await state.finish({revision:queue.revision,ok:true});assert.deepEqual(state.effects,['/auth/login','error']);
}));
