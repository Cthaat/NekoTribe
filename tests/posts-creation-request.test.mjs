// Exercise the checked-in routes, body conversion and pre-write validation.
// A single observation hook captures the private payload after validation;
// it does not replace any parser or business validation. The Oracle adapter
// accepts every relation ID so these vectors assert request semantics only.
// Authentication is pre-established. Real Oracle, hydration and notification
// integration remain covered by their separate contracts and acceptance work.
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
const fixture = JSON.parse(readFileSync(
  new URL('../specifications/scenarios/post-create-request-vectors.json', import.meta.url),
  'utf8'
));
assert.equal(new Set(fixture.cases.map(item => item.id)).size, fixture.cases.length);

const stubs = {
  '~/server/models/v2': `export const v2RequirePostById = async connection => connection.observed;
    const unused = () => { throw new Error('unexpected model'); };
    export const v2CommentCount = unused, v2MapComment = unused, v2MapPost = unused,
      v2MapPublicUser = unused, v2PostCountSql = unused, v2PostSelectSql = unused,
      v2SortOrder = unused;`,
  './notifications': 'export const v2CreateNotification = async () => null;',
  './api-cache': `export const readApiResponseCache = async () => ({status: 'disabled'});
    export const writeApiResponseCache = async () => {};
    export const invalidateApiResponseCache = async () => {};
    export const shouldInvalidateApiResponseCache = () => false;`,
  './logging': `export const getRequestLogContext = () => null;
    export const logError = () => {};
    export const logInfo = () => {};
    export const serializeLogError = () => ({});`,
  oracledb: 'export default {OUT_FORMAT_OBJECT: 4002};'
};

// This anchor is immediately after post-type/content validation and before
// source visibility checks, sequence allocation or the first database write.
const observationAnchor = '  const sourcePostId = payload.reply_to_post_id ?? payload.repost_of_post_id ?? payload.quoted_post_id ?? null;';
const compiled = await build({
  stdin: {
    contents: `export {default as create} from './server/api/v2/posts/index.post';
      export {default as retweet} from './server/api/v2/posts/[id]/retweets.post';`,
    resolveDir: root,
    loader: 'ts'
  },
  bundle: true,
  write: false,
  platform: 'node',
  format: 'esm',
  plugins: [{
    name: 'observe-post-request-boundary',
    setup(builder) {
      builder.onResolve({filter: /.*/}, args => {
        if (Object.hasOwn(stubs, args.path)) return {path: args.path, namespace: 'stub'};
        if (args.path.startsWith('~/')) return {path: path.join(root, `${args.path.slice(2)}.ts`)};
        if (args.path.startsWith('node:')) return {path: args.path, external: true};
        if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) {
          return {path: pathToFileURL(require.resolve(args.path)).href, external: true};
        }
      });
      builder.onLoad({filter: /.*/, namespace: 'stub'}, args => ({
        contents: stubs[args.path],
        loader: 'js'
      }));
      builder.onLoad({filter: /services[\\/]v2[\\/]posts\.ts$/}, args => {
        const source = readFileSync(args.path, 'utf8');
        assert.equal(source.split(observationAnchor).length, 2, 'one pre-write observation boundary');
        return {
          contents: source.replace(observationAnchor,
            '  event.context.observeRequest(payload, postType);\n' + observationAnchor),
          loader: 'ts'
        };
      });
    }
  }]
});
const routes = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

function database() {
  return {
    observed: undefined,
    writes: 0,
    close: async () => {},
    commit: async () => {},
    rollback: async () => {},
    async execute(raw) {
      const sql = raw.replace(/\s+/g, ' ').trim();
      if (sql.startsWith('SELECT seq_post_id')) return {rows: [{ID: 100}]};
      if (sql.startsWith('SELECT COALESCE')) return {rows: [{NAME: 'viewer'}]};
      if (sql.startsWith('SELECT p.post_id')) return {rows: [{POST_ID: 3}]};
      if (sql.startsWith('SELECT author_id')) return {rows: [{AUTHOR_ID: 2}]};
      if (sql.startsWith('SELECT DBMS_LOB.SUBSTR')) return {rows: [{CONTENT: 'posted'}]};
      if (/^(INSERT INTO n_posts|INSERT INTO n_post_media|MERGE INTO n_tags|INSERT INTO n_post_tags|INSERT INTO n_post_mentions)/.test(sql)) {
        this.writes++;
        return {rowsAffected: 1};
      }
      throw new Error(`unexpected SQL ${sql}`);
    }
  };
}

async function invoke(vector, connection) {
  const request = {
    method: 'POST',
    url: vector.route === 'create' ? '/api/v2/posts' : `/api/v2/posts/${vector.path_id}/retweets`,
    headers: {'content-type': 'application/json'},
    body: vector.raw_body ?? JSON.stringify(vector.body)
  };
  const response = new ServerResponse(request);
  const event = createEvent(request, response);
  event.context.auth = {userId: 1};
  event.context.params = {id: vector.path_id};
  event.context.getOracleConnection = async () => connection;
  event.context.observeRequest = (payload, postType) => {
    // Normalize absence only; all conversions and validation came from Nuxt.
    connection.observed = {
      post_type: postType,
      input: {
        content: payload.content,
        visibility: payload.visibility,
        location: payload.location ?? '',
        media_ids: payload.media_ids ?? [],
        tag_names: payload.tag_names ?? [],
        mention_user_ids: payload.mention_user_ids ?? [],
        reply_to_post_id: payload.reply_to_post_id ?? null,
        repost_of_post_id: payload.repost_of_post_id ?? null,
        quoted_post_id: payload.quoted_post_id ?? null
      }
    };
  };
  try {
    return await routes[vector.route](event);
  } finally {
    assert.equal(response.getHeader('Cache-Control'), 'private, no-store');
    response.destroy();
  }
}

test('valid JSON numeric overflow keeps Nuxt string and finite-array conversions', async () => {
  const connection = database();
  const result = await invoke({route: 'create', raw_body: '{"content":1e400,"location":-1e400,"media_ids":[1e400,-1e400,1.25],"mention_user_ids":[1e400,7.5],"tag_names":[1e400]}'}, connection);
  assert.equal(result.code, 200);
  assert.equal(connection.observed.input.content, 'Infinity');
  assert.equal(connection.observed.input.location, '-Infinity');
  assert.deepEqual(connection.observed.input.media_ids, [1.25]);
  assert.deepEqual(connection.observed.input.mention_user_ids, [7.5]);
  assert.deepEqual(connection.observed.input.tag_names, ['Infinity']);
});

for (const vector of fixture.cases) {
  test(`post creation request: ${vector.id}`, async () => {
    const connection = database();
    if (vector.expected.status === 200) {
      const response = await invoke(vector, connection);
      assert.deepEqual({
        status: 200,
        code: response.code,
        message: response.message,
        ...response.data
      }, vector.expected);
      assert.equal(response.meta, null);
      assert.ok(connection.writes > 0);
    } else {
      await assert.rejects(invoke(vector, connection), error => {
        assert.deepEqual({
          status: error.statusCode,
          code: error.data?.code,
          message: error.data?.message
        }, vector.expected);
        return true;
      });
      assert.equal(connection.observed, undefined);
      assert.equal(connection.writes, 0);
    }
  });
}
