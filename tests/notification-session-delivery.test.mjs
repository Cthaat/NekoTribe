import assert from 'node:assert/strict';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';
import {build} from 'esbuild';

// The session manager's diagnostic output is irrelevant to these assertions.
console.log = () => {};

const root = fileURLToPath(new URL('../', import.meta.url));
const bundled = await build({
  entryPoints: [fileURLToPath(new URL('../server/utils/wsSession.ts', import.meta.url))],
  absWorkingDir: root, bundle: true, write: false, platform: 'node', format: 'esm'
});
const module = await import(`data:text/javascript;base64,${Buffer.from(bundled.outputFiles[0].text).toString('base64')}`);

const message = {type: 'notification_created', data: {id: 7}, timestamp: 100};
function peer() {
  return {messages: [], closed: 0, send(value) { this.messages.push(JSON.parse(value)); }, close() { this.closed++; }};
}
function register(id, userId, target, authorize, dispose = () => {}) {
  return module.sessionManager.addSession(id, target, {userId, sessionId: id, jti: `jti-${id}`, type: 'access'}, authorize, dispose);
}
function cleanup(...ids) { ids.forEach(id => module.sessionManager.removeSession(id)); }

test('notification delivery validates each matching session and closes revoked ones', async () => {
  const valid = peer(), revoked = peer(), other = peer();
  let checks = 0;
  register('valid', 42, valid, async () => { checks++; return true; });
  register('revoked', 42, revoked, async () => false);
  register('other', 9, other, async () => { throw new Error('wrong user checked'); });
  try {
    await module.sendWsNotificationToUser(42, message);
    assert.deepEqual(valid.messages, [message]);
    assert.deepEqual(revoked.messages, []);
    assert.equal(revoked.closed, 1);
    assert.deepEqual(other.messages, []);
    assert.equal(checks, 1);
  } finally { cleanup('valid', 'revoked', 'other'); }
});

test('local and Redis room delivery drop the room when channel access is revoked', async () => {
  const target = peer();
  const room = 'chat:channel:7';
  const frame = {type: 'chat_message', room, data: {channel_id: 7}, timestamp: 100};
  let allowed = true;
  const dropped = [];
  module.sessionManager.addSession('room-auth', target, {userId:42, sessionId:'room-auth', jti:'test', type:'access'},
    async () => true, () => {}, {authorize: async id => id === 7 && allowed, leave: id => dropped.push(id)});
  module.sessionManager.joinRoom('room-auth', room);
  try {
    await module.sendWsToRoom(room, frame);
    assert.deepEqual(target.messages, [frame]);
    allowed = false;
    await module.sendWsRawToSession('room-auth', JSON.stringify(frame));
    await module.sendWsToRoom(room, frame);
    assert.deepEqual(target.messages, [frame]);
    assert.deepEqual(dropped, [7]);
    assert.equal(target.closed, 0);
  } finally { cleanup('room-auth'); }
});

test('failed verification and removal while verification is pending do not leak events', async () => {
  const failed = peer(), removed = peer();
  let finish;
  register('failed', 42, failed, async () => { throw new Error('private database error'); });
  register('removed', 42, removed, () => new Promise(resolve => { finish = resolve; }));
  try {
    const sending = module.sendWsNotificationToUser(42, message);
    await new Promise(resolve => setImmediate(resolve));
    module.sessionManager.removeSession('removed');
    finish(true);
    await sending;
    assert.deepEqual(failed.messages, []);
    assert.equal(failed.closed, 1);
    assert.deepEqual(removed.messages, []);
  } finally { cleanup('failed', 'removed'); }
});

test('a slow session is closed when its bounded notification queue fills', async () => {
  const slow = peer();
  let finish;
  register('slow', 42, slow, () => new Promise(resolve => { finish = resolve; }));
  try {
    const deliveries = Array.from({length: 17}, () => module.sendWsNotificationToUser(42, message));
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(slow.closed, 1);
    if (finish) finish(true);
    await Promise.all(deliveries);
    assert.deepEqual(slow.messages, []);
  } finally { cleanup('slow'); }
});

test('a stalled session check eventually closes the connection', async () => {
  const stalled = peer();
  register('stalled', 42, stalled, () => new Promise(() => {}));
  try {
    await Promise.race([
      module.sendWsNotificationToUser(42, message),
      new Promise((_, reject) => setTimeout(() => reject(new Error('verification did not time out')), 2_500))
    ]);
    assert.equal(stalled.closed, 1);
    assert.deepEqual(stalled.messages, []);
  } finally { cleanup('stalled'); }
});

test('periodic checks close revoked sessions and stop later room, user and broadcast sends', async () => {
  const valid = peer(), revoked = peer();
  register('periodic-valid', 42, valid, async () => true);
  register('periodic-revoked', 42, revoked, async () => false);
  module.sessionManager.joinRoom('periodic-valid', 'room');
  module.sessionManager.joinRoom('periodic-revoked', 'room');
  try {
    await module.revalidateWsSessions();
    assert.equal(valid.closed, 0);
    assert.equal(revoked.closed, 1);
    await module.sendWsToRoom('room', message);
    await module.sendWsToUser(42, message);
    await module.sendWsToAll(message);
    assert.equal(valid.messages.length, 3);
    assert.equal(revoked.messages.length, 0);
  } finally { cleanup('periodic-valid', 'periodic-revoked'); }
});

test('a session removed while periodic verification runs is not closed again', async () => {
  const removed = peer();
  let finish;
  register('periodic-removed', 42, removed, () => new Promise(resolve => { finish = resolve; }));
  try {
    const checking = module.revalidateWsSessions();
    await new Promise(resolve => setImmediate(resolve));
    module.sessionManager.removeSession('periodic-removed');
    finish(false);
    await checking;
    assert.equal(removed.closed, 0);
  } finally { cleanup('periodic-removed'); }
});

test('periodic verification limits database checks to sixteen at a time', async () => {
  const ids = Array.from({length: 20}, (_, i) => `bounded-${i}`);
  const resolvers = [];
  ids.forEach(id => register(id, 42, peer(), () => new Promise(resolve => resolvers.push(resolve))));
  try {
    const checking = module.revalidateWsSessions();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(resolvers.length, 16);
    resolvers.splice(0).forEach(resolve => resolve(true));
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(resolvers.length, 4);
    resolvers.splice(0).forEach(resolve => resolve(true));
    await checking;
  } finally { cleanup(...ids); }
});

test('idle cleanup closes the socket instead of leaving an unmanaged connection', () => {
  const idle = peer();
  register('idle', 42, idle, async () => true);
  const session = module.sessionManager.getSession('idle');
  session.lastActivity = Date.now() - 100;
  try {
    module.sessionManager.cleanupInactiveSessions(50);
    assert.equal(idle.closed, 1);
    assert.equal(module.sessionManager.getSession('idle'), undefined);
  } finally { cleanup('idle'); }
});

test('local presence broadcast revalidates each connection before delivery', async () => {
  const revoked=peer(),valid=peer();
  register('presence-revoked',42,revoked,async()=>false);
  register('presence-valid',9,valid,async()=>true);
  const presence={type:'presence_update',data:{user_id:9,online_status:'hidden',last_seen_at:null,server_id:'peer'},timestamp:1};
  try{
    await module.sendWsToAll(presence);
    assert.deepEqual(revoked.messages,[]);assert.equal(revoked.closed,1);assert.deepEqual(valid.messages,[presence]);
  }finally{cleanup('presence-revoked','presence-valid');}
});

test('queue overflow disposes the subscription and immediately releases the session slot', async () => {
  let disposed=0;const target=peer();
  register('overflow-dispose',42,target,()=>new Promise(()=>{}),()=>disposed++);
  try{
    const sending=Array.from({length:17},()=>module.sendWsNotificationToUser(42,message));
    await Promise.all(sending);
    assert.equal(disposed,1);assert.equal(target.closed,1);assert.equal(module.sessionManager.getSession('overflow-dispose'),undefined);
    cleanup('overflow-dispose');assert.equal(disposed,1);
  }finally{cleanup('overflow-dispose');}
});

test('session registration is capped and cannot replace an active identity', () => {
  const ids=Array.from({length:1025},(_,index)=>'capacity-'+index);
  try{
    ids.forEach(id=>register(id,42,peer(),async()=>true));
    assert.equal(module.sessionManager.getSession(ids.at(-1)),undefined);
    const first=module.sessionManager.getSession(ids[0]);
    assert.equal(register(ids[0],9,peer(),async()=>true),false);
    assert.equal(module.sessionManager.getSession(ids[0]),first);
  }finally{cleanup(...ids);}
});

test('only an exact observed local echo is deduplicated for the same connection',async()=>{
 const a=peer(),b=peer();a.wires=[];a.send=function(raw){this.wires.push(raw);this.messages.push(JSON.parse(raw));};
 register('echo-a',42,a,async()=>true);register('echo-b',42,b,async()=>true);
 const local={type:'notification_created',data:{id:7,server_id:module.WS_SERVER_ID,text:'prefix'+String.fromCharCode(0xd83d)+'...'},timestamp:1};
 try{
  await module.sendWsNotificationToUser(42,local);assert.equal(a.messages.length,1);assert.equal(b.messages.length,1);
  await module.sendWsRawToSession('echo-a',JSON.stringify(local));assert.equal(a.messages.length,1);
  const unknown={...local,timestamp:2};const raw='  '+JSON.stringify(unknown)+' \n';
  await module.sendWsRawToSession('echo-a',raw);assert.equal(a.wires.at(-1),raw);assert.equal(a.messages.length,2);assert.equal(b.messages.length,1);
  await module.sendWsRawToSession('echo-b',JSON.stringify(unknown));assert.equal(b.messages.length,2);
 }finally{cleanup('echo-a','echo-b');}
});

test('echo memory is bounded, expires and is cleared with the session',async()=>{
 const target=peer();register('echo-bounded',42,target,async()=>true);const now=Date.now;
 try{
  for(let id=0;id<130;id++)await module.sendWsNotificationToUser(42,{...message,data:{id,server_id:module.WS_SERVER_ID}});
  const session=module.sessionManager.getSession('echo-bounded');assert.equal(session.localEchoes.size,128);
  assert([...session.localEchoes.keys()].every(key=>/^[a-f0-9]{64}$/.test(key)));
  const latest=JSON.stringify({...message,data:{id:129,server_id:module.WS_SERVER_ID}});
  await module.sendWsRawToSession('echo-bounded',latest);assert.equal(target.messages.length,130);
  const later=now()+61000;Date.now=()=>later;
  await module.sendWsRawToSession('echo-bounded',latest);assert.equal(target.messages.length,131);
  cleanup('echo-bounded');assert.equal(session.localEchoes.size,0);
 }finally{Date.now=now;cleanup('echo-bounded');}
});

test('oversized UTF8 frames and socket backlog close and release their subscriptions',async()=>{
 for(const mode of ['frame','buffer','closed']){
  const target=peer();target.terminated=0;target.terminate=()=>target.terminated++;
  let disposed=0;const id='wire-'+mode;register(id,42,target,async()=>true,()=>disposed++);
  if(mode!=='frame')target.websocket={readyState:mode==='closed'?3:1,bufferedAmount:mode==='buffer'?4194304:0};
  try{
   await module.sendWsEventToSession(id,{...message,data:{text:mode==='frame'?'界'.repeat(100000):'normal'}});
   assert.equal(target.terminated,1);assert.equal(disposed,1);assert.equal(target.messages.length,0);assert.equal(module.sessionManager.getSession(id),undefined);
  }finally{cleanup(id);}
 }
});
