import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const stubs = {
  '~/server/utils/v2': `
    export const v2Auth=e=>e.auth, v2Body=async e=>e.body;
    export const v2Boolean=v=>v===true||v===1||(typeof v==='string'&&['1','true','yes'].includes(v.toLowerCase()));
    export const v2NumberArray=v=>Array.isArray(v)?v.map(x=>x===null||x===''?null:(typeof x==='number'||typeof x==='string')?Number(x):NaN).filter(Number.isFinite):[];
    export const v2BadRequest=message=>{throw new Error(message)};
    export const v2Execute=async(_c,sql,binds)=>{globalThis.__batch.calls.push({sql,binds});if(globalThis.__batch.failAt===globalThis.__batch.calls.length)throw new Error('write failed');return 1};
    export const v2Ok=data=>({code:200,message:'success',data,meta:null});
    export const v2Count=()=>{},v2DateString=()=>{},v2JsonValue=()=>{},v2NextId=()=>{},v2NotFound=()=>{},v2Null=()=>{},v2Number=()=>{},v2One=()=>{},v2Page=()=>{},v2PageMeta=()=>{},v2QueryString=()=>{},v2RequiredNumber=()=>{},v2Rows=()=>{},v2String=()=>{};
  `,
  '~/server/models/v2': 'export const v2GetPublicUser=()=>{},v2MapNotification=()=>{};',
  '~/server/utils/wsSession': 'export const WS_SERVER_ID="test";export const sendWsNotificationToUser=async(user,message)=>globalThis.__batch.events.push({user,message});',
  '~/server/utils/redis': 'export const REDIS_CHANNELS={USER_MESSAGE:"ws:user:"};export const publishMessage=async(channel,message)=>globalThis.__batch.events.push({channel,message});'
};
const bundle = await build({
  stdin: { contents: `export {v2BatchSetNotificationReadStatus} from './server/services/v2/notifications';`, resolveDir: root, loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'batch-stubs', setup(builder) {
    builder.onResolve({ filter: /.*/ }, args => {
      if (Object.hasOwn(stubs, args.path)) return { path: args.path, namespace: 'stub' };
      if (args.path.startsWith('~/')) return { path: path.join(root, `${args.path.slice(2)}.ts`) };
      if (args.path.startsWith('node:')) return { path: args.path, external: true };
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) return { path: pathToFileURL(require.resolve(args.path)).href, external: true };
    });
    builder.onLoad({ filter: /.*/, namespace: 'stub' }, args => ({ contents: stubs[args.path], loader: 'js' }));
  } }]
});
const { v2BatchSetNotificationReadStatus } = await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`);

test('invalid ID selections never update all notifications or publish', async () => {
  for (const ids of ['oops', null, ['bad'], [2, null], [0], [-1], [1.5], [Number.MAX_SAFE_INTEGER + 1], ['12'], Array(1001).fill(1)]) {
    globalThis.__batch = { calls: [], events: [] };
    await assert.rejects(v2BatchSetNotificationReadStatus({ auth: { userId: 42 }, body: { notification_ids: ids, is_read: true } }, {}), /notification_ids/);
    assert.equal(globalThis.__batch.calls.length, 0, JSON.stringify(ids));
    assert.equal(globalThis.__batch.events.length, 0);
  }
  delete globalThis.__batch;
});

test('all and selected modes remain scoped and publish the matching event', async () => {
  for (const ids of [undefined, [], [7, 7, 8]]) {
    globalThis.__batch = { calls: [], events: [] };
    const result = await v2BatchSetNotificationReadStatus({ auth: { userId: 42 }, body: { notification_ids: ids, is_read: true } }, {});
    const all = ids === undefined || ids.length === 0;
    assert.equal(result.data.updated_count, all ? 1 : 3);
    for (const call of globalThis.__batch.calls) {
      assert.match(call.sql, /user_id\s*=\s*:user_id/);
      assert.equal(call.binds.user_id, 42);
      assert.equal(call.binds.is_read, 1);
      assert.equal(/deleted_at\s+IS\s+NULL/i.test(call.sql), all);
    }
    assert.equal(globalThis.__batch.events[0].message.type, 'notifications_read_status_updated');
    assert.equal(globalThis.__batch.events[0].user, 42);
  }
  delete globalThis.__batch;
});

test('a later update failure stops the batch and publishes no success event', async () => {
  globalThis.__batch = { calls: [], events: [], failAt: 2 };
  try {
    await assert.rejects(v2BatchSetNotificationReadStatus({ auth: { userId: 42 }, body: { notification_ids: [7, 8, 9], is_read: true } }, {}), /write failed/);
    assert.equal(globalThis.__batch.calls.length, 2);
    assert.equal(globalThis.__batch.calls[0].binds.notification_id, 7);
    assert.equal(globalThis.__batch.calls[1].binds.notification_id, 8);
    assert.equal(globalThis.__batch.events.length, 0);
  } finally { delete globalThis.__batch; }
});
