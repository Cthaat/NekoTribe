import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { fakePeer,loadRealtimeRoute,routeState,waitFor } from './helpers/realtime-route.mjs';
import state from '../specifications/requirements/webrtc-call-state.json' with {type:'json'};

const root = fileURLToPath(new URL('../',import.meta.url));
const built = await build({
  entryPoints:['server/services/v2/webrtc-calls.ts'],absWorkingDir:root,bundle:true,write:false,platform:'node',format:'esm',
  plugins:[{name:'ice-auth-fixture',setup(builder) {
    const stubs = {
      h3:`export const setResponseHeader=(event,key,value)=>event.headers[key]=value;`,
      '~/server/utils/v2':`export const v2Auth=event=>({userId:event.userId}),v2Ok=data=>({data});
        export const v2Throw=statusCode=>{throw Object.assign(new Error(),{statusCode});};`,
    };
    builder.onResolve({filter:/.*/},({path})=>Object.hasOwn(stubs,path)?{path,namespace:'stub'}:undefined);
    builder.onLoad({filter:/.*/,namespace:'stub'},({path})=>({contents:stubs[path]}));
  }}],
});
const ice = await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const ws = await loadRealtimeRoute();
const callerId = '11111111-1111-1111-1111-111111111111';
const calleeId = '22222222-2222-2222-2222-222222222222';
const callId = '33333333-3333-3333-3333-333333333333';

test('ICE configuration returns temporary TURN credentials and never the deployment secret', () => {
  const env = {WEBRTC_STUN_URLS:'stun:example.test, stun:example.test',
    WEBRTC_TURN_URLS:'turn:relay.example.test:3478?transport=tcp',WEBRTC_TURN_SHARED_SECRET:'synthetic-test-key'};
  const result = ice.callIceConfiguration(42,env,1_000_000);
  assert.deepEqual(result.ice_servers[0],{urls:['stun:example.test']});
  assert.equal(result.ice_servers[1].username,'15700:42');
  assert.match(result.ice_servers[1].credential,/^[A-Za-z0-9+/]{27}=$/);
  assert.equal(result.expires_at,new Date(15_700_000).toISOString().replace('.000Z','Z'));
  assert(!JSON.stringify(result).includes(env.WEBRTC_TURN_SHARED_SECRET));
  assert.deepEqual(ice.callIceConfiguration(42,{},0),{ice_servers:[],expires_at:null});
  assert.throws(()=>ice.callIceConfiguration(42,{WEBRTC_TURN_URLS:env.WEBRTC_TURN_URLS},0),{statusCode:503});
  assert.throws(()=>ice.callIceConfiguration(42,{WEBRTC_STUN_URLS:'stun:example.test:65536'},0),{statusCode:503});
});

test('socket calls negotiate only with the accepting socket and release on disconnect', async () => {
  let stored = null;
  const evals = [];
  const callRedis = {
    get: async () => stored && JSON.stringify(stored),
    async eval(lua,count,key,actorKey,peerKey,action,id,conversation,actor,peer,client,connection,mode) {
      assert.equal(lua,state.lines.join('\n'));
      assert.equal(count,3);
      assert.equal(key,`nt:{webrtc}:call:${id}`);
      assert.deepEqual([actorKey,peerKey],[`nt:{webrtc}:user:${actor}`,`nt:{webrtc}:user:${peer}`]);
      evals.push(action);
      if (action === 'invite') {
        if (stored) return ['busy',''];
        stored = {call_id:id,conversation_id:String(conversation),caller_id:String(actor),callee_id:String(peer),
          mode,caller_client_id:client,caller_connection:connection,stage:'ringing'};
      }
      if (action === 'accept') {
        stored = {...stored,callee_client_id:client,callee_connection:connection,stage:'await_offer'};
      }
      if (action === 'offer') assert.equal(connection,stored.caller_connection);
      if (action === 'disconnect') {
        const result = stored;
        stored = null;
        return ['ok',JSON.stringify(result)];
      }
      return ['ok',JSON.stringify(stored)];
    },
  };
  globalThis.__wsRoute = routeState({callRedis,directTypingPeer:(user, conversation) =>
    conversation === 7 ? ({42:43,43:42}[user] ?? null) : null});
  const caller = fakePeer(), callee = fakePeer('user43'), otherDevice = fakePeer('user43'), stranger = fakePeer('user9');
  const peers = [caller,callee,otherDevice,stranger];
  const send = (peer,type,client_id,extra = {}) => ws.handler.message(peer,
    {text:()=>JSON.stringify({type,data:{call_id:callId,conversation_id:7,client_id,...extra}})});
  const count = (peer,type) => peer.messages.filter(event=>event.type===type).length;
  try {
    for (const peer of peers) await ws.handler.open(peer);
    await send(stranger,'call_invite',callerId,{mode:'voice'});
    assert.equal(evals.length,0);
    await send(caller,'call_invite',callerId,{mode:'voice'});
    await waitFor(()=>count(callee,'call_invite')===1 && count(otherDevice,'call_invite')===1);
    await send(caller,'call_invite',callerId,{mode:'voice',call_id:'44444444-4444-4444-4444-444444444444'});
    assert.equal(count(caller,'call_busy'),1);
    await send(callee,'call_accept',calleeId);
    await waitFor(()=>count(caller,'call_accept')===1);
    await send(caller,'call_sdp_offer',callerId,{sdp:'v=0\r\n'});
    await waitFor(()=>count(callee,'call_sdp_offer')===1);
    assert.equal(count(otherDevice,'call_sdp_offer') + count(stranger,'call_sdp_offer'),0);
    const messages = globalThis.__wsRoute.published;
    assert.deepEqual(messages.filter(([,frame])=>frame.type==='call_sdp_offer').map(([channel])=>channel),['ws:user:43']);
    assert(!messages.some(([,frame])=>'caller_connection' in frame.data));
    await ws.handler.close(caller);
    await waitFor(()=>count(callee,'call_hangup')===1);
    assert.equal(stored,null);
  } finally {
    for (const peer of peers) if (peer.sessionId) ws.sessionManager.removeSession(peer.sessionId);
    delete globalThis.__wsRoute;
  }
});
