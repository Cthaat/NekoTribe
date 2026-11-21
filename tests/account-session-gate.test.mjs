import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {parse,compileScript,compileTemplate} from '@vue/compiler-sfc';
import {build} from 'esbuild';
import * as vue from 'vue';
globalThis.__preferencesVue=vue;
const root=fileURLToPath(new URL('../',import.meta.url));
const {descriptor}=parse(readFileSync(root+'app/components/AccountSessionGate.vue','utf8'));
const script=compileScript(descriptor,{id:'account-session-gate'});
const template=compileTemplate({source:descriptor.template.content,id:'account-session-gate',filename:'AccountSessionGate.vue',compilerOptions:{bindingMetadata:script.bindings}});
if(template.errors.length)throw Error(JSON.stringify(template.errors));
const source=script.content.replace('export default','const component =')+'\n'+template.code.replace('export function render','function render')+'\ncomponent.render=render;export default component;export {authQueueFor} from "./app/services/auth-request-queue";';
const built=await build({stdin:{contents:source,resolveDir:root,loader:'ts'},alias:{'@':root+'app'},bundle:true,write:false,platform:'node',format:'esm',banner:{js:'const useAppLocale=()=>({t:x=>x});'},plugins:[{name:'gate-boundaries',setup(b){
 b.onResolve({filter:/^(vue|#app|@\/components\/ui\/button)$/},args=>({path:args.path,namespace:'stub'}));
 b.onLoad({filter:/.*/,namespace:'stub'},({path})=>({contents:
  path==='vue'?Object.keys(vue).filter(k=>/^[a-zA-Z_$][\w$]*$/.test(k)).map(k=>'export const '+k+'=globalThis.__preferencesVue.'+k+';').join('\n'):
  path==='#app'?'export const useNuxtApp=()=>globalThis.__preferencesGate.owner;':
  'export const Button={inheritAttrs:false,setup(props,{attrs,slots}){return()=>globalThis.__preferencesVue.h("button",attrs,slots.default?.());}};'
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
async function fixture(run,beforeMount){
 const owner={},queue=api.authQueueFor(owner),state={owner,mounts:0,unmounts:0};globalThis.__preferencesGate=state;
 const child={setup(){state.mounts++;vue.onUnmounted(()=>state.unmounts++);return()=>vue.h('section',{'data-preferences':true},'preferences');}};
 const rootNode={children:[]},app=renderer.createApp({render:()=>vue.h(api.default,null,{default:()=>vue.h(child)})});
 const pending=beforeMount?.(queue);app.mount(rootNode);
 const all=()=>{const out=[];const walk=n=>{out.push(n);for(const c of n.children??[])walk(c);};walk(rootNode);return out;};
 try{await run({state,queue,all,pending});}finally{app.unmount();delete globalThis.__preferencesGate;}
}
test('actual account gate removes the whole preferences instance and explicitly remounts a fresh one',()=>fixture(async({state,queue,all})=>{
 assert.equal(state.mounts,1);queue.beginIdentityChange();await vue.nextTick();assert.equal(state.unmounts,1);assert(!all().some(n=>n.props?.['data-preferences']));
 all().find(n=>n.type==='button').props.onClick();await vue.nextTick();assert.equal(state.mounts,2);
}));
test('pending identity blocks reopening even through retained direct callbacks',()=>fixture(async({state,queue,all})=>{
 let finish;const pending=queue.runIdentityChange(()=>new Promise(r=>{finish=r;}));await vue.nextTick();
 const button=all().find(n=>n.type==='button');assert.equal(button.props.disabled,true);button.props.onClick();await vue.nextTick();assert.equal(state.mounts,1);
 finish();await pending;await vue.nextTick();all().find(n=>n.type==='button').props.onClick();await vue.nextTick();assert.equal(state.mounts,2);
}));
test('ordinary refresh and an independent app cannot invalidate current preferences',()=>fixture(async({state,queue})=>{
 await queue.run(async()=>{});api.authQueueFor({}).beginIdentityChange();await vue.nextTick();assert.equal(state.unmounts,0);
}));
