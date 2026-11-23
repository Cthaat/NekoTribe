import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { effectScope, ref } from 'vue';
import { waitFor } from './helpers/realtime-route.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const vue = import.meta.resolve('vue');
const compiled = await build({
  absWorkingDir:root,entryPoints:['app/composables/useWebRtcCalls.ts'],bundle:true,write:false,platform:'node',format:'esm',
  plugins:[{name:'webrtc-media-fixture',setup(builder) {
    const stubs = {
      '#app':`export const useNuxtApp=()=>globalThis.__callClient.app;`,
      '@/api/v2/users':`export const v2GetUserById=async()=>({display_name:'Other member'});`,
      '@/api/v2/webrtc':`export const v2GetCallIceServers=async()=>[{urls:['stun:test.invalid']}];`,
      '@/stores/user':`export const usePreferenceStore=()=>({preferences:{user:{id:42}}});`,
      './useRealtimeSocket':`export const useRealtimeSocket=()=>globalThis.__callClient.realtime;`,
    };
    builder.onResolve({filter:/^vue$/},()=>({path:vue,external:true}));
    builder.onResolve({filter:/.*/},({path})=>Object.hasOwn(stubs,path)?{path,namespace:'fixture'}:undefined);
    builder.onLoad({filter:/.*/,namespace:'fixture'},({path})=>({contents:stubs[path]}));
  }}],
});
const {useWebRtcCalls}=await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

test('web caller waits for consent, applies queued ICE after the answer and releases media on hangup', async t => {
  const sent = [];
  let listener, peer, requested, stopped = 0;
  class FakeRtc {
    candidates = [];
    constructor(options) { assert.deepEqual(options.iceServers,[{urls:['stun:test.invalid']}]); peer=this; }
    addTrack() {}
    createOffer() { return {type:'offer',sdp:'test offer'}; }
    setLocalDescription(value) { this.localDescription=value; }
    setRemoteDescription(value) { this.remoteDescription=value; }
    addIceCandidate(candidate) { assert(this.remoteDescription); this.candidates.push(candidate); }
    close() { this.closed=true; }
  }
  const fixture = {
    app:{runWithContext:work=>work()},
    realtime:{serverReady:ref(true),ownerRevision:ref(1),
      subscribe(fn) { listener=fn;return ()=>{listener=undefined;}; },
      send(frame) { sent.push(frame); return true; },
    },
  };
  const globals = {__callClient:fixture,isSecureContext:true,RTCPeerConnection:FakeRtc,navigator:{mediaDevices:{
    async getUserMedia(constraints) { requested=constraints;return {getTracks:()=>[{stop(){stopped++;}}]}; },
  }}};
  const prior = Object.fromEntries(Object.keys(globals).map(key=>[key,Object.getOwnPropertyDescriptor(globalThis,key)]));
  for (const [key,value] of Object.entries(globals)) Object.defineProperty(globalThis,key,{value,configurable:true,writable:true});
  const scope = effectScope();
  const calls = scope.run(useWebRtcCalls);
  const release = calls.attach();
  t.after(()=>{
    release();scope.stop();
    for (const [key,descriptor] of Object.entries(prior)) if (descriptor) Object.defineProperty(globalThis,key,descriptor); else delete globalThis[key];
  });
  assert.equal(requested,undefined);
  await calls.start(7,43,'Other member','voice');
  assert.deepEqual(requested,{audio:true,video:false});
  assert.equal(sent[0].type,'call_invite');
  assert.equal(peer,undefined);
  const invite = sent[0].data;
  const frame = (type,extra = {}) => ({type,timestamp:Date.now(),data:{call_id:invite.call_id,conversation_id:7,caller_id:42,callee_id:43,
    mode:'voice',caller_client_id:invite.client_id,callee_client_id:'other-device',...extra}});
  listener(frame('call_accept'));
  await waitFor(()=>sent.some(item=>item.type==='call_sdp_offer'));
  assert.equal(calls.call.value.phase,'connecting');
  listener(frame('call_ice',{candidates:[{candidate:'test candidate',sdp_mline_index:0}]}));
  listener(frame('call_sdp_answer',{sdp:'test answer'}));
  await waitFor(()=>peer.candidates.length===1);
  assert.equal(peer.remoteDescription.type,'answer');
  peer.connectionState='connected';peer.onconnectionstatechange();
  assert.equal(calls.call.value.phase,'active');
  calls.end();
  assert.equal(sent.at(-1).type,'call_hangup');
  assert.equal(stopped,1);
  assert.equal(peer.closed,true);
  assert.equal(calls.call.value,null);
});
