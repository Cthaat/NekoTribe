import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {ServerResponse} from 'node:http';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';
import {createEvent} from 'h3';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const fixture = JSON.parse(readFileSync(new URL('../specifications/scenarios/post-delete.json', import.meta.url), 'utf8'));
const stubs = {
  '~/server/models/v2': `const unused = () => { throw new Error('unexpected model'); };
    export const v2RequirePostById=unused, v2CommentCount=unused, v2MapComment=unused,
      v2MapPost=unused, v2MapPublicUser=unused, v2PostCountSql=unused, v2PostSelectSql=unused, v2SortOrder=unused;`,
  './notifications': 'export const v2CreateNotification = () => { throw new Error("unexpected notification"); };',
  './api-cache': `export const readApiResponseCache=async()=>({status:'disabled'});
    export const writeApiResponseCache=async()=>{}, invalidateApiResponseCache=async()=>{};
    export const shouldInvalidateApiResponseCache=()=>false;`,
  './logging': `export const getRequestLogContext=()=>null, logError=()=>{}, logInfo=()=>{}, serializeLogError=()=>({});`,
  oracledb: 'export default {OUT_FORMAT_OBJECT:4002};'
};
const compiled = await build({
  stdin: {contents: `export {default} from './server/api/v2/posts/[id].delete';`, resolveDir: root, loader: 'ts'},
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{name: 'isolated-post-delete', setup(builder) {
    builder.onResolve({filter: /.*/}, args => {
      if (Object.hasOwn(stubs, args.path)) return {path: args.path, namespace: 'stub'};
      if (args.path.startsWith('~/')) return {path: path.join(root, `${args.path.slice(2)}.ts`)};
      if (args.path.startsWith('node:')) return {path: args.path, external: true};
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) return {path: pathToFileURL(require.resolve(args.path)).href, external: true};
    });
    builder.onLoad({filter: /.*/, namespace: 'stub'}, args => ({contents: stubs[args.path], loader: 'js'}));
  }}]
});
const route = (await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`)).default;

for (const vector of fixture.cases) test(`post delete: ${vector.id}`, async () => {
  const calls = [];
  const connection = {
    async execute(raw, binds, options) {
      const sql = raw.replace(/\s+/g, ' ').trim();
      calls.push({sql, binds, options});
      if (vector.state === 'query-error' && sql.startsWith('SELECT')) throw new Error('private driver detail');
      if (sql.startsWith('SELECT')) return {rows: vector.state === 'missing' ? [] : [{AUTHOR_ID: vector.state === 'other' ? 7 : 42, IS_DELETED: vector.state === 'deleted' ? 1 : 0}]};
      assert.match(sql, /^UPDATE n_posts SET is_deleted\s*=\s*1 WHERE/);
      assert.match(sql, /author_id\s*=\s*:user_id/);
      assert.match(sql, /is_deleted\s*=\s*0/);
      assert.deepEqual(binds, {post_id: 20, user_id: 42});
      assert.equal(options.autoCommit, true);
      if (vector.state === 'write-error') throw new Error('private driver detail');
      return {rowsAffected: vector.state === 'race' ? 0 : 1};
    },
    async close() { if (vector.state === 'close-error') throw new Error('private close detail'); }
  };
  const request = {method: 'DELETE', url: `/api/v2/posts/${vector.path_id}`, headers: {}, body: '{broken ignored'};
  const response = new ServerResponse(request);
  const event = createEvent(request, response);
  event.context.auth = {userId: 42};
  event.context.params = {id: vector.path_id};
  event.context.getOracleConnection = async () => connection;
  try {
    if (vector.expected.status === 200) {
      const actual = await route(event);
      assert.deepEqual(actual, {code: 200, message: 'post deleted', data: null, meta: null});
    } else {
      await assert.rejects(route(event), error => {
        assert.deepEqual({status: error.statusCode, code: error.data?.code, message: error.data?.message}, vector.expected);
        assert.ok(!String(error).includes('private'));
        return true;
      });
    }
    assert.equal(response.getHeader('Cache-Control'), 'private, no-store');
    if (vector.expected.status === 400) assert.equal(calls.length, 0);
    if (['missing', 'deleted', 'other', 'query-error'].includes(vector.state)) assert.ok(calls.every(call => call.sql.startsWith('SELECT')));
  } finally { response.destroy(); }
});
