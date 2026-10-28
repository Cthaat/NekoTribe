// Real route/middleware/service/model code with an isolated Oracle adapter.
// The adapter models the checked-in fn_can_view_post policy; it is not an Oracle engine.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { build } from 'esbuild';
import jwt from 'jsonwebtoken';
import { createApp, createRouter, defineEventHandler, toNodeListener } from 'h3';
import { schemaFixture } from './helpers/schema-fixture.mjs';
import { listenForFetch } from './helpers/loopback-listener.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const secret = 'isolated-posts-access-secret';
const stubs = {
  '#imports': `export const useRuntimeConfig = () => ({accessSecret: ${JSON.stringify(secret)}});`,
  '~/server/storage': 'export const normalizeAvatarPublicUrl = value => value; export const normalizeNullableStoragePublicUrl = value => value; export const normalizeStoragePublicUrl = value => value;',
  './notifications': 'export const v2CreateNotification = async (connection, notification) => { connection.interactions.notifications.push(notification); };',
  '~/server/utils/redis': 'export const REDIS_CHANNELS = {USER_MESSAGE:"ws:user:"}; export const publishMessage = async () => {};',
  '~/server/utils/wsSession': 'export const WS_SERVER_ID = "isolated-test"; export const sendWsToUser = () => {}; export const sendWsNotificationToUser = async () => {};',
  './api-cache': 'export const readApiResponseCache = async () => ({status:"disabled"}); export const writeApiResponseCache = async () => {}; export const invalidateApiResponseCache = async () => {}; export const shouldInvalidateApiResponseCache = () => false;',
  './logging': 'export const getRequestLogContext = () => null; export const logError = () => {}; export const logInfo = () => {}; export const serializeLogError = () => ({});',
  oracledb: 'export default {OUT_FORMAT_OBJECT: 4002};'
};
const compiled = await build({
  stdin: {contents: `
    export {default as auth} from './server/middleware/auth';
    export {default as list} from './server/api/v2/posts/index.get';
    export {default as trending} from './server/api/v2/posts/trending.get';
    export {default as get} from './server/api/v2/posts/[id].get';
    export {default as create} from './server/api/v2/posts/index.post';
    export {default as createRetweet} from './server/api/v2/posts/[id]/retweets.post';
    export {default as remove} from './server/api/v2/posts/[id].delete';
    export {default as update} from './server/api/v2/posts/[id].put';
    export {default as me} from './server/api/v2/users/me/posts.get';
    export {default as bookmarks} from './server/api/v2/users/me/bookmarks.get';
    export {default as likes} from './server/api/v2/users/me/likes.get';
    export {default as userPosts} from './server/api/v2/users/[id]/posts.get';
    export {default as tagPosts} from './server/api/v2/tags/[name]/posts.get';
    export {default as tags} from './server/api/v2/tags/index.get';
    export {default as trendingTags} from './server/api/v2/tags/trending.get';
    export {default as tagAnalytics} from './server/api/v2/tags/[name]/analytics.get';
    export {default as notifications} from './server/api/v2/notifications/index.get';
    export {default as replies} from './server/api/v2/posts/[id]/replies.get';
    export {default as retweets} from './server/api/v2/posts/[id]/retweets.get';
    export {default as comments} from './server/api/v2/posts/[id]/comments.get';
    export {default as createComment} from './server/api/v2/posts/[id]/comments.post';
    export {default as deleteComment} from './server/api/v2/comments/[id].delete';
    export {default as likeComment} from './server/api/v2/comments/[id]/likes.post';
    export {default as unlikeComment} from './server/api/v2/comments/[id]/likes.delete';
    export {default as like} from './server/api/v2/posts/[id]/likes.post';
    export {default as unlike} from './server/api/v2/posts/[id]/likes.delete';
    export {default as bookmark} from './server/api/v2/posts/[id]/bookmarks.post';
    export {default as unbookmark} from './server/api/v2/posts/[id]/bookmarks.delete';
    export {v2ListPosts} from './server/services/v2/posts';
    export {defineV2Handler} from './server/utils/v2';
  `, resolveDir: root, loader: 'ts'},
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{name: 'isolated-boundaries', setup(builder) {
    builder.onResolve({filter: /.*/}, args => {
      if (Object.hasOwn(stubs, args.path)) return {path: args.path, namespace: 'test-stub'};
      if (args.path.startsWith('~/')) return {path: path.join(root, `${args.path.slice(2)}.ts`)};
      if (args.path.startsWith('node:')) return {path: args.path, external: true};
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) return {path: pathToFileURL(require.resolve(args.path)).href, external: true};
    });
    builder.onLoad({filter: /.*/, namespace: 'test-stub'}, args => ({contents: stubs[args.path], loader: 'js'}));
  }}]
});
const routes = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text + '\n//# sourceURL=isolated-posts-bundle.mjs').toString('base64')}`);
const access = (payload = {}, options = {}) => jwt.sign({userId: 1, userName: 'viewer', sessionId: 'session', jti: 'current', type: 'access', ...payload}, secret, {expiresIn: 600, ...options});

function database({revoked = false, expiredSession = false, failSession = false, missingMediaSchema = false, failList = false, failTags = false, tagAnalytics = {}, allowSecondViewer = false, loseVisibility = false, loseParentOnInsert = false, failCommentRead = false, failNotifications = false, deleteRace = false} = {}) {
  const schema = schemaFixture({ baseline: true });
  if (missingMediaSchema) {
    const table = schema.state.tables.get('N_MEDIA_ASSETS');
    table.columns = table.columns.filter(column => column.COLUMN_NAME !== 'DESCRIPTION');
  }
  const calls = [];
  const interactions = {likes: new Set(), bookmarks: new Set(), notifications: [], comments: [], createdPosts: [], visibilityChecks: 0};
  interactions.commentLikes = new Set();
  const deleteComments = new Map([[20,{user:1,post:1,deleted:false}],[21,{user:2,post:1,deleted:false}],[22,{user:1,post:2,deleted:false}],[23,{user:1,post:1,deleted:true}]]);
  const posts = [
    {POST_ID: 1, AUTHOR_ID: 2, VISIBILITY: 'public'},
    {POST_ID: 2, AUTHOR_ID: 2, VISIBILITY: 'private'},
    {POST_ID: 3, AUTHOR_ID: 2, VISIBILITY: 'followers'},
    {POST_ID: 4, AUTHOR_ID: 2, VISIBILITY: 'mentioned', mentioned: 1},
    {POST_ID: 5, AUTHOR_ID: 1, VISIBILITY: 'private'},
    {POST_ID: 6, AUTHOR_ID: 2, VISIBILITY: 'public', deleted: true},
    {POST_ID: 7, AUTHOR_ID: 3, VISIBILITY: 'public'}
  ];
  return {
    calls, interactions, close: async () => {},
    async execute(raw, binds = {}) {
      const sql = raw.replace(/\s+/g, ' ').trim(); calls.push({sql, binds});
      const metadata = schema.query(sql, binds);
      if (metadata !== undefined) return {rows: metadata};
      if (sql.startsWith('UPDATE n_auth_sessions')) {
        if (failSession) throw new Error('isolated database failure');
        const live = (binds.userId === 1 || (allowSecondViewer && binds.userId === 2)) && binds.sessionId === 'session' && binds.accessJti === 'current' && !revoked && (!expiredSession || !sql.includes('access_token_expires_at > CURRENT_TIMESTAMP'));
        return {rowsAffected: live ? 1 : 0};
      }
      if (sql.startsWith('SELECT seq_comment_id.NEXTVAL')) return {rows:[{ID:100}]};
      if (sql.startsWith('SELECT seq_post_id.NEXTVAL')) return {rows:[{ID:100}]};
      if (sql.startsWith('INSERT INTO n_posts')) {
        if (binds.source_post_id && (loseVisibility || ![1,5].includes(binds.source_post_id))) return {rowsAffected:0};
        interactions.createdPosts.push({...binds});
        posts.push({POST_ID:binds.post_id,AUTHOR_ID:binds.author_id,VISIBILITY:binds.visibility});
        return {rowsAffected:1};
      }
      if (sql.startsWith('SELECT c.comment_id') && sql.includes('FROM n_comments c') && sql.includes('JOIN n_posts p')) {
        const c=deleteComments.get(binds.comment_id);
        const visible=c && !c.deleted && c.post===1 && binds.viewer_id===1 && !(deleteRace && interactions.visibilityChecks++ > 0);
        if (!visible) return {rows:[]};
        if (sql.includes('likes_count')) return {rows:[{LIKES_COUNT:interactions.commentLikes.has(binds.comment_id)?1:0}]};
        return {rows:[{COMMENT_ID:binds.comment_id}]};
      }
      if (/^(INSERT INTO|DELETE FROM) n_comment_likes/.test(sql)) {
        const c=deleteComments.get(binds.comment_id);
        const guarded=sql.includes('fn_can_view_post') && sql.includes('c.is_deleted = 0') && sql.includes('p.is_deleted = 0');
        if (!guarded || !c || c.deleted || c.post!==1 || binds.user_id!==1 || deleteRace) return {rowsAffected:0};
        if (sql.startsWith('INSERT')) {const fresh=!interactions.commentLikes.has(binds.comment_id); interactions.commentLikes.add(binds.comment_id);return {rowsAffected:fresh?1:0};}
        return {rowsAffected:interactions.commentLikes.delete(binds.comment_id)?1:0};
      }
      if (sql.startsWith('SELECT c.user_id') && sql.includes('FROM n_comments c')) {
        const c=deleteComments.get(binds.comment_id);
        const visible=c && !c.deleted && c.post===1 && binds.viewer_id===1;
        return {rows:visible?[{USER_ID:c.user}]:[]};
      }
      if (sql.startsWith('UPDATE n_comments')) {
        const c=deleteComments.get(binds.comment_id);
        const guarded=sql.includes('fn_can_view_post') && sql.includes('user_id = :user_id') && sql.includes('is_deleted = 0');
        if (!guarded || !c || c.deleted || c.user!==binds.user_id || c.post!==1 || deleteRace) return {rowsAffected:0};
        c.deleted=true;
        return {rowsAffected:1};
      }
      if (sql.startsWith('INSERT INTO n_comments')) {
        const guarded = sql.includes('fn_can_view_post');
        const allowed = [1,5].includes(binds.post_id) && binds.user_id === 1 && !loseVisibility;
        if (guarded && (!allowed || (loseParentOnInsert && binds.parent_comment_id))) return {rowsAffected:0};
        interactions.comments.push({...binds});
        return {rowsAffected:1};
      }
      if (sql.startsWith('SELECT NVL(root_comment_id, comment_id)')) return {rows: binds.comment_id === 40 && binds.post_id === 1 ? [{ROOT_COMMENT_ID:30}] : []};
      if (sql.includes('FROM n_comments') && sql.includes('DBMS_LOB.SUBSTR')) return {rows:[{USER_ID:binds.comment_id===40?3:1,POST_ID:1,CONTENT:binds.comment_id===40?'parent':'comment'}]};
      if (sql.startsWith('SELECT user_id FROM n_comments')) return {rows:binds.comment_id===40?[{USER_ID:3}]:[]};
      if (sql.includes('FROM n_notifications')) {
        if (failNotifications) throw new Error('private-notification-database-error');
        if (sql.startsWith('SELECT COUNT')) return {rows: [{TOTAL: 3}]};
        return {rows: [{NOTIFICATION_ID: 12, ACTOR_ID: 7, TYPE: 'like', TITLE: 'title', MESSAGE: 'message', RESOURCE_TYPE: 'post', RESOURCE_ID: 9, PRIORITY: 'normal', IS_READ: 0, METADATA_JSON: '{"event":"post_like"}', CREATED_AT: new Date('2026-01-02T03:04:05.000Z')}]};
      }
      if (sql.includes('FROM n_posts p') && sql.includes('fn_can_view_post')) {
        interactions.visibilityChecks++;
        const exists = [1, 5].includes(binds.post_id) && binds.viewer_id === 1 && !(loseVisibility && interactions.visibilityChecks > 1);
        return {rows: exists ? [{POST_ID: binds.post_id}] : []};
      }
      if (sql.includes('FROM v_post_comment_list_item')) {
        if (sql.startsWith('SELECT COUNT')) return {rows: [{TOTAL: 0}]};
        if (sql.includes('c.comment_id = :comment_id') && interactions.comments.length) {
          if (failCommentRead) throw new Error('private comment read error');
          const c=interactions.comments.at(-1);
          return {rows:[{COMMENT_ID:c.comment_id,POST_ID:c.post_id,USER_ID:c.user_id,PARENT_COMMENT_ID:c.parent_comment_id,ROOT_COMMENT_ID:c.root_comment_id,CONTENT:c.content,LIKES_COUNT:0,REPLIES_COUNT:0,IS_LIKED:0,CREATED_AT:new Date('2026-01-02T03:04:05Z'),UPDATED_AT:new Date('2026-01-02T03:04:05Z')}]};
        }
        return {rows: []};
      }
      if (/^(INSERT INTO|DELETE FROM) n_post_(likes|bookmarks)/.test(sql)) {
        const kind = sql.includes('n_post_likes') ? interactions.likes : interactions.bookmarks;
        const key = `${binds.post_id}:${binds.user_id}`;
        const visible = [1, 5].includes(binds.post_id) && binds.user_id === 1 && !loseVisibility;
        if (!visible) return {rowsAffected: 0};
        if (sql.startsWith('INSERT')) {const inserted = !kind.has(key); kind.add(key); return {rowsAffected: inserted ? 1 : 0};}
        return {rowsAffected: kind.delete(key) ? 1 : 0};
      }
      if (sql.startsWith('SELECT likes_count FROM n_post_stats')) return {rows: [{LIKES_COUNT: interactions.likes.has(`${binds.post_id}:1`) ? 1 : 0}]};
      if (sql.startsWith('SELECT author_id FROM n_posts')) return {rows: [{AUTHOR_ID: 2}]};
      if (sql.includes('FROM n_users') && sql.includes('COALESCE(display_name')) return {rows: [{NAME: 'viewer'}]};
      if (sql.includes('DBMS_LOB.SUBSTR(content') && sql.includes('FROM n_posts')) return {rows: [{CONTENT: 'post'}]};
      if (sql.includes('FROM n_tags t') || sql.includes('FROM v_tag_analytics')) {
        if (tagAnalytics.failure) throw new Error('private-tag-analytics-error');
        if (tagAnalytics.missing) return {rows: []};
        const empty = tagAnalytics.zero || (allowSecondViewer && binds.viewer_id === 2);
        return {rows: [{NAME: 'C# cats', TOTAL_POSTS: empty ? 0 : 2, TOTAL_AUTHORS: empty ? 0 : 1, TOTAL_VIEWS: empty ? 0 : 30, TOTAL_LIKES: empty ? 0 : 4, AVG_ENGAGEMENT_SCORE: empty ? 0 : 2.75}]};
      }
      if (sql.includes('FROM n_tags') && !sql.includes('n_post_tags')) {
        if (failTags) throw new Error('private-tag-database-error');
        if (sql.startsWith('SELECT COUNT')) return {rows: [{TOTAL: 3}]};
        return {rows: [{TAG_ID: 17, NAME: 'Cat', USAGE_COUNT: 42, TRENDING_SCORE: 12.5, IS_TRENDING: 1, UPDATED_AT: new Date('2026-01-02T03:04:05.000Z')}]};
      }
      if (sql.includes('FROM v_post_feed_item v')) {
        if (failList) throw new Error('private-database-error SQL secret');
        let visible = posts.filter(post => !post.deleted);
        if (sql.includes('fn_can_view_post(:viewer_id, v.post_id) = 1')) visible = visible.filter(post =>
          post.VISIBILITY === 'public' || post.AUTHOR_ID === binds.viewer_id ||
          (binds.viewer_id === 1 && ((post.VISIBILITY === 'followers' && post.AUTHOR_ID === 2) || post.mentioned === 1)));
        if (sql.includes('f.following_id = v.author_id') && sql.includes("f.status = 'active'")) visible = visible.filter(post => binds.viewer_id === 1 && post.AUTHOR_ID === 2);
        if (sql.includes('pm.mentioned_user_id = :viewer_id')) visible = visible.filter(post => post.mentioned === binds.viewer_id);
        if (sql.includes('AND v.author_id = :author_id')) visible = visible.filter(post => post.AUTHOR_ID === binds.author_id);
        if (sql.includes('FROM n_post_bookmarks b')) visible = visible.filter(post => binds.viewer_id === 1 && post.POST_ID === 1);
        if (sql.includes('FROM n_post_likes l')) visible = visible.filter(post => binds.viewer_id === 1 && post.POST_ID === 7);
        if (sql.includes('AND v.post_id = :post_id')) visible = visible.filter(post => post.POST_ID === binds.post_id);
        if (sql.startsWith('SELECT COUNT')) return {rows: [{TOTAL: visible.length}]};
        return {rows: visible.sort((a, b) => b.POST_ID - a.POST_ID).slice(binds.start_row - 1, binds.end_row).map(post => ({...post, CONTENT: `post ${post.POST_ID}`, POST_TYPE: 'original', IS_LIKED: 0, IS_BOOKMARKED: 0}))};
      }
      if (sql.includes('FROM v_user_profile_public u')) return {rows: [{USER_ID: binds.user_id, USERNAME: 'author', RELATION: binds.viewer_id === binds.user_id ? 'self' : 'none'}]};
      if (sql.includes('FROM n_post_media') || sql.includes('FROM n_post_tags') || sql.includes('FROM n_post_mentions')) return {rows: []};
      if (sql.startsWith('UPDATE n_post_stats')) return {rowsAffected: 1};
      throw new Error(`Unexpected isolated SQL: ${sql}`);
    }
  };
}

async function fixture(options) {
  const db = options?.db ?? database(options);
  const app = createApp();
  app.use(defineEventHandler(event => {event.context.getOracleConnection = async () => db;}));
  app.use(routes.auth);
  const router = createRouter();
  router.get('/api/v2/posts', routes.list);
  router.get('/api/v2/posts/trending', routes.trending);
  router.get('/api/v2/posts/:id', routes.get);
  router.post('/api/v2/posts', routes.create);
  router.post('/api/v2/posts/:id/retweets', routes.createRetweet);
  router.put('/api/v2/posts/:id', routes.update);
  router.delete('/api/v2/posts/:id', routes.remove);
  router.get('/api/v2/users/me/posts', routes.me);
  router.get('/api/v2/users/me/bookmarks', routes.bookmarks);
  router.get('/api/v2/users/me/likes', routes.likes);
  router.get('/api/v2/users/:id/posts', routes.userPosts);
  router.get('/api/v2/tags/:name/posts', routes.tagPosts);
  router.get('/api/v2/tags', routes.tags);
  router.get('/api/v2/tags/trending', routes.trendingTags);
  router.get('/api/v2/tags/:name/analytics', routes.tagAnalytics);
  router.get('/api/v2/notifications', routes.notifications);
  router.get('/api/v2/posts/:id/replies', routes.replies);
  router.get('/api/v2/posts/:id/retweets', routes.retweets);
  router.get('/api/v2/posts/:id/comments', routes.comments);
  router.post('/api/v2/posts/:id/comments', routes.createComment);
  router.delete('/api/v2/comments/:id', routes.deleteComment);
  router.post('/api/v2/comments/:id/likes', routes.likeComment);
  router.delete('/api/v2/comments/:id/likes', routes.unlikeComment);
  router.post('/api/v2/posts/:id/likes', routes.like);
  router.delete('/api/v2/posts/:id/likes', routes.unlike);
  router.post('/api/v2/posts/:id/bookmarks', routes.bookmark);
  router.delete('/api/v2/posts/:id/bookmarks', routes.unbookmark);
  router.get('/api/v2/groups/:id/posts', defineEventHandler(() => {throw new Error('Anonymous group route was reached');}));
  // Exercise the service guards independently of route-level auth for these modes.
  for (const mode of ['me', 'bookmarks', 'likes']) router.get(`/isolated/${mode}`, routes.defineV2Handler((event, connection) => routes.v2ListPosts(event, connection, {mode})));
  app.use(router);
  const server = createServer(toNodeListener(app));
  const base = await listenForFetch(server);
  return {db, close: () => new Promise(resolve => server.close(resolve)), request: (url, headers = {}, method = 'GET', body) => fetch(base + url, {method, headers, ...(body === undefined ? {} : {body:JSON.stringify(body)})})};
}

test('post replies quotes and reposts require visible source at insertion', async () => {
  const headers={authorization:`Bearer ${access()}`,'content-type':'application/json'};
  const f=await fixture();
  try {
    for(const field of ['reply_to_post_id','quoted_post_id','repost_of_post_id']) {
      for(const id of [2,6,999]) {
        const response=await f.request('/api/v2/posts',headers,'POST',{content:'content',[field]:id});
        assert.equal(response.status,404,`${field} ${id}`);
      }
    }
    assert.equal((await f.request('/api/v2/posts/2/retweets',headers,'POST',{})).status,404);
    assert.equal((await f.request('/api/v2/posts/01/retweets',headers,'POST',{})).status,400);
    for (const invalid of ['01',1.5,9007199254740992,{},-1,0]) {
      assert.equal((await f.request('/api/v2/posts',headers,'POST',{content:'invalid reference',reply_to_post_id:invalid})).status,400,JSON.stringify(invalid));
    }
    assert.equal((await f.request('/api/v2/posts',headers,'POST',{content:'multiple references',reply_to_post_id:1,quoted_post_id:1})).status,400);
    assert.equal(f.db.interactions.createdPosts.length,0);
    const response=await f.request('/api/v2/posts',headers,'POST',{content:'a reply',reply_to_post_id:1});
    assert.equal(response.status,200,await response.clone().text());
    const write=f.db.calls.find(x=>x.sql.startsWith('INSERT INTO n_posts'));
    assert.match(write.sql,/fn_can_view_post\(:author_id,\s*p\.post_id\)/);
    assert.equal(write.binds.source_post_id,1);
    assert.equal(write.binds.author_id,1);
    assert.equal(f.db.interactions.notifications[0].metadata.event,'post_reply');
  } finally {await f.close();}
  const ordinary=await fixture();
  try {
    const response=await ordinary.request('/api/v2/posts',headers,'POST',{content:'standalone'});
    assert.equal(response.status,200,await response.clone().text());
    const write=ordinary.db.calls.find(x=>x.sql.startsWith('INSERT INTO n_posts'));
    assert.equal(Object.hasOwn(write.binds,'source_post_id'),false);
    assert.doesNotMatch(write.sql,/fn_can_view_post/);
  } finally {await ordinary.close();}
  const retweet=await fixture();
  try {
    const response=await retweet.request('/api/v2/posts/1/retweets',headers,'POST',{});
    assert.equal(response.status,200,await response.clone().text());
    assert.equal(retweet.db.interactions.notifications[0].metadata.event,'post_repost');
  } finally {await retweet.close();}
  const race=await fixture({loseVisibility:true});
  try {const response=await race.request('/api/v2/posts',headers,'POST',{content:'race',quoted_post_id:1});assert.equal(response.status,404);assert.equal(race.db.interactions.createdPosts.length,0);}
  finally {await race.close();}
});

test('comment likes require visibility at each step and notify only for new likes', async () => {
  const headers={authorization:`Bearer ${access()}`};
  const f=await fixture();
  try {
    assert.equal((await f.request('/api/v2/comments/20/likes',{},'POST')).status,401);
    assert.equal((await f.request('/api/v2/comments/020/likes',headers,'POST')).status,400);
    for(const method of ['POST','DELETE']) for(const id of [22,23,24]) assert.equal((await f.request(`/api/v2/comments/${id}/likes`,headers,method)).status,404);
    for(const [method,liked,count] of [['POST',true,1],['POST',true,1],['DELETE',false,0],['DELETE',false,0]]) {
      const response=await f.request('/api/v2/comments/20/likes',headers,method);
      assert.equal(response.status,200);assert.equal(response.headers.get('cache-control'),'private, no-store');
      const body=await response.json();assert.deepEqual(body.data,{comment_id:20,is_liked:liked,likes_count:count});
    }
    assert.equal(f.db.interactions.notifications.length,1);
    assert.equal(f.db.interactions.notifications[0].metadata.event,'comment_like');
    for(const call of f.db.calls.filter(x=>/^(INSERT INTO|DELETE FROM) n_comment_likes/.test(x.sql))) {
      assert.match(call.sql,/fn_can_view_post\(:user_id,\s*c\.post_id\)/);assert.equal(call.binds.user_id,1);
    }
  } finally {await f.close();}
  const race=await fixture({deleteRace:true});
  try {assert.equal((await race.request('/api/v2/comments/20/likes',headers,'POST')).status,404);}
  finally {await race.close();}
});

test('comment deletion requires visible owner at check and write', async () => {
  const headers={authorization:`Bearer ${access()}`};
  const f=await fixture();
  try {
    assert.equal((await f.request('/api/v2/comments/20',{},'DELETE')).status,401);
    assert.equal((await f.request('/api/v2/comments/020',headers,'DELETE')).status,400);
    for (const id of [22,23,24]) assert.equal((await f.request(`/api/v2/comments/${id}`,headers,'DELETE')).status,404);
    assert.equal((await f.request('/api/v2/comments/21',headers,'DELETE')).status,422);
    const response=await f.request('/api/v2/comments/20',headers,'DELETE');
    assert.equal(response.status,200);
    assert.equal(response.headers.get('cache-control'),'private, no-store');
    assert.deepEqual(await response.json(),{code:200,message:'comment deleted',data:null,meta:null});
    const update=f.db.calls.find(call=>call.sql.startsWith('UPDATE n_comments'));
    assert.match(update.sql,/fn_can_view_post\(:user_id,\s*(?:c\.)?post_id\)/);
    assert.equal(update.binds.comment_id,20);assert.equal(update.binds.user_id,1);
    assert.equal((await f.request('/api/v2/comments/20',headers,'DELETE')).status,404);
  } finally {await f.close();}
  const race=await fixture({deleteRace:true});
  try {assert.equal((await race.request('/api/v2/comments/20',headers,'DELETE')).status,404);}
  finally {await race.close();}
});

test('creating comments requires visibility at write and valid parent on the same post', async () => {
  const headers={authorization:`Bearer ${access()}`,'content-type':'application/json'};
  const f=await fixture();
  try {
    assert.equal((await f.request('/api/v2/posts/1/comments',{'content-type':'application/json'},'POST',{content:'anonymous'})).status,401);
    assert.equal((await f.request('/api/v2/posts/01/comments',headers,'POST',{content:'invalid id'})).status,400);
    assert.equal((await f.request('/api/v2/posts/2/comments',headers,'POST',{content:'secret'})).status,404);
    assert.equal(f.db.interactions.comments.length,0);
    for (const parent of ['01', 1.5, 9007199254740992, {}, -1]) {
      assert.equal((await f.request('/api/v2/posts/1/comments',headers,'POST',{content:'reply',parent_comment_id:parent})).status,400,JSON.stringify(parent));
    }
    assert.equal((await f.request('/api/v2/posts/1/comments',headers,'POST',{content:'  '})).status,400);
    assert.equal((await f.request('/api/v2/posts/1/comments',headers,'POST',{content:'reply',parent_comment_id:99})).status,404);
    assert.equal(f.db.interactions.comments.length,0);
    const response=await f.request('/api/v2/posts/1/comments',headers,'POST',{content:' reply ',parent_comment_id:40});
    assert.equal(response.status,200);const body=await response.json();
    assert.equal(body.data.content,'reply');assert.equal(body.data.root_comment_id,30);assert.equal(body.data.parent_comment_id,40);
    const insert=f.db.calls.find(call=>call.sql.startsWith('INSERT INTO n_comments'));
    assert.match(insert.sql,/fn_can_view_post\(:user_id,\s*:post_id\)/);
    assert.match(insert.sql,/EXISTS\s*\(\s*SELECT 1 FROM n_comments parent[^]*parent\.comment_id\s*=\s*:parent_comment_id[^]*parent\.post_id\s*=\s*:post_id[^]*parent\.is_deleted\s*=\s*0/i);
    assert.equal(insert.binds.user_id,1);assert.equal(insert.binds.post_id,1);
    const read=f.db.calls.find(call=>call.sql.includes('FROM v_post_comment_list_item') && call.sql.includes('c.comment_id = :comment_id'));
    assert.match(read.sql,/fn_can_view_post\(:viewer_id,\s*c\.post_id\)/);
    assert.equal(read.binds.viewer_id,1);assert.equal(read.binds.post_id,1);
    assert.equal(f.db.interactions.notifications.length,2);
    assert.deepEqual(f.db.interactions.notifications.map(n=>[n.userId,n.metadata.event]),[[2,'comment_created'],[3,'comment_reply']]);
  } finally {await f.close();}
  const root=await fixture();
  try {
    const response=await root.request('/api/v2/posts/1/comments',headers,'POST',{content:'root'});
    assert.equal(response.status,200);const body=await response.json();
    assert.equal(body.data.comment_id,100);assert.equal(body.data.root_comment_id,100);assert.equal(body.data.parent_comment_id,null);
    assert.deepEqual(root.db.interactions.notifications.map(n=>n.metadata.event),['comment_created']);
  } finally {await root.close();}
  const race=await fixture({loseVisibility:true});
  try {
    const response=await race.request('/api/v2/posts/1/comments',headers,'POST',{content:'race'});
    assert.equal(response.status,404);assert.equal(race.db.interactions.comments.length,0);
  } finally {await race.close();}
  const parentRace=await fixture({loseParentOnInsert:true});
  try {
    const response=await parentRace.request('/api/v2/posts/1/comments',headers,'POST',{content:'race',parent_comment_id:40});
    assert.equal(response.status,404);assert.equal(parentRace.db.interactions.comments.length,0);
  } finally {await parentRace.close();}
  const committed=await fixture({failCommentRead:true});
  try {
    const response=await committed.request('/api/v2/posts/1/comments',headers,'POST',{content:'committed'});
    assert.equal(response.status,500);assert.equal(committed.db.interactions.comments.length,1);
    assert.equal(committed.db.interactions.notifications.length,0);
    assert.doesNotMatch(await response.text(),/private comment read error/);
  } finally {await committed.close();}
});

test('comment list requires post visibility and protects count and rows independently', async () => {
  const f = await fixture();
  const headers = {authorization: `Bearer ${access()}`};
  try {
    assert.equal((await f.request('/api/v2/posts/1/comments')).status, 401);
    const denied = await f.request('/api/v2/posts/2/comments', headers);
    assert.equal(denied.status, 404);
    assert.equal(f.db.calls.filter(call => call.sql.includes('v_post_comment_list_item')).length, 0);
    const response = await f.request('/api/v2/posts/1/comments?sort=popular', headers);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'private, no-store');
    const body = await response.json();
    assert.deepEqual(body.data, []);
    const calls = f.db.calls.filter(call => call.sql.includes('v_post_comment_list_item'));
    assert.equal(calls.length, 2);
    for (const call of calls) {
      assert.match(call.sql, /fn_can_view_post\(:viewer_id,\s*(?:c\.)?post_id\)\s*=\s*1/);
      assert.equal(call.binds.viewer_id, 1);
      assert.equal(call.binds.post_id, 1);
    }
    assert.equal((await f.request('/api/v2/posts/01/comments', headers)).status, 400);
  } finally { await f.close(); }
});

test('anonymous public list uses null viewer, correct visibility/count/pagination and neutral viewer state', async () => {
  const f = await fixture();
  try {
    const response = await f.request('/api/v2/posts?page=1&page_size=1'); assert.equal(response.status, 200);
    const body = await response.json(); assert.deepEqual(body.data.map(post => post.post_id), [7]);
    assert.deepEqual(body.meta, {page: 1, page_size: 1, total: 2, has_next: true});
    assert.deepEqual(body.data[0].viewer_state, {is_liked: false, is_bookmarked: false, can_delete: false});
    const page2 = await (await f.request('/api/v2/posts?page=2&page_size=1')).json(); assert.deepEqual(page2.data.map(post => post.post_id), [1]); assert.equal(page2.meta.has_next, false);
    assert.ok(f.db.calls.filter(call => call.sql.includes('FROM v_post_feed_item')).every(call => call.binds.viewer_id === null && call.sql.includes('fn_can_view_post')));
  } finally {await f.close();}
});

test('post list binds search and pagination consistently for count and selected rows', async () => {
  const f = await fixture();
  try {
    const response = await f.request('/api/v2/posts?q=%20%23%23Cat_%25%20&sort=popular&page=2&page_size=3');
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.deepEqual(body.meta, {page: 2, page_size: 3, total: 2, has_next: false});
    const queries = f.db.calls.filter(call => call.sql.includes('FROM v_post_feed_item v'));
    assert.equal(queries.length, 2);
    for (const call of queries) {
      assert.equal(call.binds.viewer_id, null);
      assert.equal(call.binds.q, '%##cat_%%');
      assert.equal(call.binds.tag_q, '%cat_%%');
      assert.match(call.sql, /fn_can_view_post\(:viewer_id, v\.post_id\) = 1/);
      assert.match(call.sql, /t\.name_lower LIKE :tag_q/);
    }
    const rows = queries.find(call => !call.sql.startsWith('SELECT COUNT'));
    assert.equal(rows.binds.start_row, 4);
    assert.equal(rows.binds.end_row, 6);
    assert.match(rows.sql, /ORDER BY v\.engagement_score DESC, v\.created_at DESC/);
  } finally {await f.close();}
});

test('post list does not expose unexpected database failures', async () => {
  const f = await fixture({failList: true});
  const errors = [];
  const previousError = console.error;
  console.error = (...args) => errors.push(args.map(String).join(' '));
  try {
    const response = await f.request('/api/v2/posts');
    const body = await response.text();
    assert.equal(response.status, 500);
    assert.ok(!body.includes('private-database-error'), body);
    assert.ok(!body.includes('SQL secret'), body);
    assert.ok(!errors.join('\n').includes('private-database-error'), errors.join('\n'));
  } finally {console.error = previousError; await f.close();}
});

test('trending forces popular order and personal modes do not log database failures', async () => {
  const f = await fixture();
  try {
    assert.equal((await f.request('/api/v2/posts/trending?sort=oldest')).status, 200);
    const row = f.db.calls.find(call => call.sql.includes('FROM v_post_feed_item v') && !call.sql.startsWith('SELECT COUNT'));
    assert.match(row.sql, /ORDER BY v\.engagement_score DESC, v\.created_at DESC/);
    const likes = await f.request('/api/v2/users/me/likes?sort=oldest', {authorization: `Bearer ${access()}`});
    assert.equal(likes.status, 200);
    const liked = f.db.calls.find(call => call.sql.includes('SELECT MAX(l.created_at)'));
    assert.match(liked.sql, /l\.user_id = :viewer_id \) ASC/);
  } finally {await f.close();}
  const broken = await fixture({failList: true});
  const errors = []; const previousError = console.error; console.error = (...args) => errors.push(args.map(String).join(' '));
  try {
    for (const url of ['/api/v2/posts/trending', '/api/v2/users/me/posts', '/api/v2/users/me/bookmarks', '/api/v2/users/me/likes']) {
      const headers = url.includes('/users/me/') ? {authorization: `Bearer ${access()}`} : {};
      const response = await broken.request(url, headers);
      assert.equal(response.status, 500, url);
      assert.ok(!(await response.text()).includes('private-database-error'), url);
    }
    assert.ok(!errors.join('\n').includes('private-database-error'));
  } finally {console.error = previousError; await broken.close();}
});

test('scoped lists require auth, use strict IDs and bind decoded targets', async () => {
  const f = await fixture();
  const headers = {authorization: `Bearer ${access()}`};
  try {
    for (const url of ['/api/v2/users/2/posts', '/api/v2/tags/C%23%20cats/posts', '/api/v2/posts/1/replies', '/api/v2/posts/1/retweets']) assert.equal((await f.request(url)).status, 401, url);
    for (const route of ['/api/v2/users/01/posts', '/api/v2/posts/1.5/replies', '/api/v2/posts/0x1/retweets', '/api/v2/users/9007199254740992/posts']) assert.equal((await f.request(route, headers)).status, 400, route);
    for (const [url, bind, value] of [['/api/v2/users/2/posts', 'author_id', 2], ['/api/v2/tags/C%23%20cats/posts', 'tag_name', 'C# cats'], ['/api/v2/posts/%31/replies', 'target_post_id', 1], ['/api/v2/posts/1/retweets', 'target_post_id', 1]]) {
      const response = await f.request(url, headers); assert.equal(response.status, 200, url);
      const count = f.db.calls.filter(call => call.sql.startsWith('SELECT COUNT') && call.binds[bind] === value).at(-1);
      assert.ok(count, url); assert.equal(count.binds.viewer_id, 1, url);
      assert.ok(!count.sql.includes('C# cats'), url);
    }
  } finally {await f.close();}
});

test('Nuxt tag list follows common route vectors', async () => {
  const vectors = JSON.parse(readFileSync(new URL('../specifications/scenarios/tag-list.json', import.meta.url)));
  for (const tc of vectors.cases) {
    const f = await fixture({revoked: tc.auth === 'revoked', failTags: tc.failure});
    const errors = []; const previousError = console.error;
    if (tc.failure) console.error = (...args) => errors.push(args.map(String).join(' '));
    try {
      const headers = tc.auth === 'none' ? {} : tc.auth === 'bad' ? {authorization: 'Bearer bad'} : tc.auth === 'bad-cookie' ? {cookie: 'access_token=bad', authorization: `Bearer ${access()}`} : tc.auth === 'cookie' ? {cookie: `access_token=${access()}`} : {authorization: `Bearer ${access()}`};
      const response = await f.request(tc.path, headers); const body = await response.json();
      assert.equal(response.status, tc.status, `${tc.id}: ${JSON.stringify(body)}`);
      assert.ok(!JSON.stringify(body).includes('private-tag-database-error'), tc.id);
      assert.ok(!errors.join('\n').includes('private-tag-database-error'), tc.id);
      if (tc.status === 200) {
        assert.deepEqual(body.data, vectors.items, tc.id);
        assert.deepEqual(body.meta, {page: tc.page, page_size: tc.size, total: 3, has_next: tc.page * tc.size < 3}, tc.id);
        const sql = f.db.calls.filter(call => call.sql.includes('FROM n_tags') && !call.sql.includes('n_post_tags'));
        assert.equal(sql.length, 2, tc.id);
        assert.ok(sql.every(call => tc.trending ? call.sql.includes('is_trending = 1') && !Object.hasOwn(call.binds, 'q') : call.binds.q === tc.q), tc.id);
        assert.ok(sql[1].sql.includes('ORDER BY trending_score DESC, usage_count DESC, updated_at DESC'), tc.id);
      }
    } finally {console.error = previousError; await f.close();}
  }
});

test('Nuxt tag analytics follows viewer-scoped common vectors', async () => {
  const vectors = JSON.parse(readFileSync(new URL('../specifications/scenarios/tag-analytics.json', import.meta.url)));
  for (const tc of vectors.cases) {
    const f = await fixture({revoked: tc.auth === 'revoked', tagAnalytics: tc});
    const errors = []; const previousError = console.error; if (tc.failure) console.error = (...args) => errors.push(args.map(String).join(' '));
    try {
      const headers = tc.auth === 'none' ? {} : tc.auth === 'bad' ? {authorization: 'Bearer bad'} : tc.auth === 'bad-cookie' ? {cookie: 'access_token=bad', authorization: `Bearer ${access()}`} : tc.auth === 'cookie' ? {cookie: `access_token=${access()}`} : {authorization: `Bearer ${access()}`};
      const response = await f.request(tc.path, headers); const body = await response.json();
      assert.equal(response.status, tc.status, `${tc.id}: ${JSON.stringify(body)}`);
      assert.ok(!JSON.stringify(body).includes('private-tag-analytics-error'), tc.id); assert.ok(!errors.join('\n').includes('private-tag-analytics-error'), tc.id);
      const calls = f.db.calls.filter(call => call.sql.includes('FROM n_tags t') || call.sql.includes('FROM v_tag_analytics'));
      if (tc.name) {
        assert.equal(calls.length, 1, tc.id); assert.equal(calls[0].binds.name, tc.name, tc.id); assert.equal(calls[0].binds.viewer_id, 1, tc.id);
        assert.match(calls[0].sql, /fn_can_view_post\(:viewer_id, p\.post_id\) = 1/, tc.id);
        assert.match(calls[0].sql, /COUNT\(DISTINCT p\.post_id\)/, tc.id);
      } else assert.equal(calls.length, 0, tc.id);
      if (tc.status === 200) {
        const expected = tc.zero ? {name: 'C# cats', total_posts: 0, total_authors: 0, total_views: 0, total_likes: 0, engagement_score: 0} : vectors.result;
        assert.deepEqual(body.data, expected, tc.id); assert.equal(response.headers.get('cache-control'), 'private, no-store', tc.id);
      }
    } finally {console.error = previousError; await f.close();}
  }
});

test('tag analytics binds each viewer and does not reuse another viewer result', async () => {
  const f = await fixture({allowSecondViewer: true});
  try {
    for (const [id, expected] of [[1, 2], [2, 0], [1, 2]]) {
      const response = await f.request('/api/v2/tags/C%23%20cats/analytics', {authorization: `Bearer ${access({userId: id})}`});
      assert.equal(response.status, 200); assert.equal((await response.json()).data.total_posts, expected);
      assert.equal(response.headers.get('cache-control'), 'private, no-store');
    }
    assert.deepEqual(f.db.calls.filter(call => call.sql.includes('FROM n_tags t')).map(call => call.binds.viewer_id), [1, 2, 1]);
  } finally {await f.close();}
});

test('post likes and bookmarks require visibility and preserve idempotent state', async () => {
  const f = await fixture(); const headers = {authorization: `Bearer ${access()}`};
  try {
    for (const action of ['likes', 'bookmarks']) for (const method of ['POST', 'DELETE']) {
      assert.equal((await f.request(`/api/v2/posts/1/${action}`, {}, method)).status, 401);
      assert.equal((await f.request(`/api/v2/posts/2/${action}`, headers, method)).status, 404);
      assert.equal((await f.request(`/api/v2/posts/99/${action}`, headers, method)).status, 404);
      assert.equal((await f.request(`/api/v2/posts/01/${action}`, headers, method)).status, 400);
    }
    assert.equal(f.db.calls.filter(call => /^(INSERT INTO|DELETE FROM) n_post_(likes|bookmarks)/.test(call.sql)).length, 0);
    for (const [action, field] of [['likes', 'is_liked'], ['bookmarks', 'is_bookmarked']]) for (const [method, value] of [['POST', true], ['POST', true], ['DELETE', false], ['DELETE', false]]) {
      const response = await f.request(`/api/v2/posts/1/${action}?user_id=99`, headers, method); const body = await response.json();
      assert.equal(response.status, 200, `${method} ${action}: ${JSON.stringify(body)}`); assert.equal(body.data[field], value);
    }
    const writes = f.db.calls.filter(call => /^(INSERT INTO|DELETE FROM) n_post_(likes|bookmarks)/.test(call.sql));
    assert.equal(writes.length, 8); assert.ok(writes.every(call => call.binds.user_id === 1 && /fn_can_view_post\(:user_id, :post_id\) = 1/.test(call.sql)));
    assert.equal(f.db.interactions.notifications.length, 1);
    assert.equal(f.db.interactions.notifications[0].userId, 2);
    assert.equal(f.db.interactions.notifications[0].actorId, 1);
    assert.equal(f.db.interactions.notifications[0].type, 'like');
    assert.equal(f.db.interactions.notifications[0].resourceId, 1);
  } finally {await f.close();}
  const f2 = await fixture({loseVisibility: true});
  try {const response = await f2.request('/api/v2/posts/1/likes', headers, 'POST'); assert.equal(response.status, 404); assert.equal(f2.db.interactions.likes.size, 0);} finally {await f2.close();}
});

test('notification list uses authenticated viewer, filters and safe errors', async () => {
  const f=await fixture(); const headers={authorization:`Bearer ${access()}`};
  try {
    assert.equal((await f.request('/api/v2/notifications')).status,401);
    const response=await f.request('/api/v2/notifications?user_id=99&type=like&unread_only=true&show_deleted=true&page=2&page_size=1',headers);
    const body=await response.json(); assert.equal(response.status,200);assert.equal(response.headers.get('cache-control'),'private, no-store');assert.equal(body.meta.total,3);assert.equal(body.meta.has_next,true);assert.equal(body.data[0].actor.user_id,7);assert.equal(body.data[0].metadata.event,'post_like');
    const queries=f.db.calls.filter(x=>x.sql.includes('FROM n_notifications'));
    assert.equal(queries.length,2);assert.ok(queries.every(x=>x.binds.user_id===1 && x.binds.type==='like' && x.sql.includes('deleted_at IS NOT NULL') && x.sql.includes('is_read = 0')));
  } finally {await f.close();}
  const broken=await fixture({failNotifications:true});
  try {const response=await broken.request('/api/v2/notifications',headers);const body=await response.text();assert.equal(response.status,500);assert.ok(!body.includes('private-notification-database-error'));} finally {await broken.close();}
});

test('anonymous detail excludes private/followers/mentioned/deleted/group posts without incrementing their views', async () => {
  const f = await fixture();
  try {
    for (const id of [2, 3, 4, 5, 6, 99]) assert.equal((await f.request(`/api/v2/posts/${id}`)).status, 404);
    assert.equal(f.db.calls.filter(call => call.sql.startsWith('UPDATE n_post_stats')).length, 0);
    assert.equal((await f.request('/api/v2/posts/1')).status, 200);
    assert.equal(f.db.calls.filter(call => call.sql.startsWith('UPDATE n_post_stats')).length, 1);
  } finally {await f.close();}
});

test('post detail uses bounded decimal IDs and is never cached', async () => {
  const f=await fixture();try {
    for(const id of ['01','1e0','0x1','1.5','9007199254740992']) assert.equal((await f.request(`/api/v2/posts/${id}`,{authorization:`Bearer ${access()}`})).status,400,id);
    assert.equal((await f.request('/api/v2/posts/01')).status,401);
    const response=await f.request('/api/v2/posts/1');assert.equal(response.status,200);assert.equal(response.headers.get('cache-control'),'private, no-store');
  } finally {await f.close();}
});

// Exercise the real middleware, route, service and mappers against the same
// language-neutral vectors as the Rust and Go handlers. This adapter simulates
// Oracle rows and failures; it does not implement the database visibility policy.
test('Nuxt post detail matches shared route and failure vectors', async () => {
  const vectors = JSON.parse(readFileSync(new URL('../specifications/scenarios/post-detail-vectors.json', import.meta.url)));
  assert.equal(vectors.cases.length, 22);
  const {post} = vectors;
  const timestamp = new Date(post.created_at);
  function userRow(user) {
    return {
      USER_ID: user.user_id, USERNAME: user.username, DISPLAY_NAME: user.display_name,
      AVATAR_URL: user.avatar_url, BIO: user.bio, LOCATION: user.location, WEBSITE: user.website,
      IS_VERIFIED: user.is_verified, FOLLOWERS_COUNT: user.followers_count,
      FOLLOWING_COUNT: user.following_count, POSTS_COUNT: user.posts_count, LIKES_COUNT: user.likes_count,
      RELATION: user.relationship.relation, ONLINE_STATUS: user.online_status,
      LAST_SEEN_AT: user.last_seen_at ? new Date(user.last_seen_at) : null
    };
  }
  for (const scenario of vectors.cases) {
    const schema = schemaFixture({baseline: true});
    if (scenario.fault === 'media-ready') {
      const table = schema.state.tables.get('N_MEDIA_ASSETS');
      table.columns = table.columns.filter(column => column.COLUMN_NAME !== 'DESCRIPTION');
    }
    const events = [];
    const stage = name => {
      events.push(name);
      if (scenario.fault === name) throw new Error('private-database-error');
    };
    const db = {
      close: async () => {},
      async execute(raw, binds = {}) {
        const sql = raw.replace(/\s+/g, ' ').trim();
        if (sql.startsWith('UPDATE n_auth_sessions')) {
          if (scenario.touch_fail) throw new Error('private-database-error');
          return {rowsAffected: !scenario.revoked && binds.userId === 42 ? 1 : 0};
        }
        if (sql.startsWith('SELECT USER AS')) {
          // A bad media schema should be reported by the real readiness code.
          events.push('media-ready');
        }
        const metadata = schema.query(sql, binds);
        if (metadata !== undefined) return {rows: metadata};
        if (sql.includes('FROM v_post_feed_item v')) {
          stage('post');
          assert.equal(binds.viewer_id, scenario.auth === 'none' ? null : 42, scenario.id);
          assert.equal(binds.post_id, 1, scenario.id);
          assert.match(sql, /fn_can_view_post\(:viewer_id, v\.post_id\) = 1/);
          if (scenario.missing) return {rows: []};
          return {rows: [{POST_ID: 1, AUTHOR_ID: 7, CONTENT: post.content, POST_TYPE: post.post_type,
            VISIBILITY: post.visibility, LANGUAGE: post.language, LOCATION: post.location,
            REPLY_TO_POST_ID: null, REPOST_OF_POST_ID: null, QUOTED_POST_ID: null,
            LIKES_COUNT: post.stats.likes_count, COMMENTS_COUNT: post.stats.comments_count,
            REPLIES_COUNT: post.stats.replies_count, RETWEETS_COUNT: post.stats.retweets_count,
            VIEWS_COUNT: post.stats.views_count, ENGAGEMENT_SCORE: post.stats.engagement_score,
            IS_LIKED: 0, IS_BOOKMARKED: 0, CREATED_AT: timestamp, UPDATED_AT: timestamp}]};
        }
        if (sql.includes('FROM v_user_profile_public u')) {
          stage('author');
          assert.equal(binds.user_id, 7, scenario.id);
          return {rows: scenario.fault === 'author-missing' ? [] : [userRow(post.author)]};
        }
        if (sql.includes('FROM n_post_media')) {
          stage('media');
          const media = post.media[0];
          return {rows: [{MEDIA_ID: media.media_id, MEDIA_TYPE: media.media_type, FILE_NAME: media.file_name,
            PUBLIC_URL: media.public_url, FILE_SIZE: media.file_size, MIME_TYPE: media.mime_type,
            WIDTH: media.width, HEIGHT: media.height, DURATION: media.duration, THUMBNAIL_URL: media.thumbnail_url,
            ALT_TEXT: media.alt_text, DESCRIPTION: media.description, STATUS: media.status, CREATED_AT: timestamp}]};
        }
        if (sql.includes('FROM n_post_tags')) {stage('tags'); return {rows: post.tags.map(NAME => ({NAME}))};}
        if (sql.includes('FROM n_post_mentions')) {stage('mentions'); return {rows: [userRow(post.mentions[0])]};}
        if (sql.startsWith('UPDATE n_post_stats')) {stage('views'); return {rowsAffected: 1};}
        throw new Error(`Unexpected isolated SQL in ${scenario.id}`);
      }
    };
    const f = await fixture({db});
    try {
      const token = access({userId: 42});
      const headers = scenario.auth === 'valid' ? {authorization: `Bearer ${token}`} :
        scenario.auth === 'cookie' ? {cookie: `access_token=${token}`} :
        scenario.auth === 'bad-cookie' ? {cookie: 'access_token=bad', authorization: `Bearer ${token}`} :
        scenario.auth === 'expired' ? {authorization: `Bearer ${access({userId: 42}, {expiresIn: -60})}`} : {};
      const response = await f.request(`/api/v2/posts/${scenario.target}?viewer_id=99`, headers);
      const body = await response.json();
      assert.equal(response.status, scenario.status, `${scenario.id}: ${JSON.stringify(body)}`);
      assert.deepEqual(events, scenario.events, scenario.id);
      assert.ok(!JSON.stringify(body).includes('private-database-error'), scenario.id);
      if (scenario.status === 200) {
        assert.deepEqual(body.data, post, scenario.id);
        assert.equal(response.headers.get('cache-control'), 'private, no-store', scenario.id);
      }
    } finally {await f.close();}
  }
});

test('missing media schema returns sanitized 503 without request-time DDL or view increments', async () => {
  const f = await fixture({missingMediaSchema: true});
  try {
    const response = await f.request('/api/v2/posts/1');
    assert.equal(response.status, 503);
    const body = await response.json();
    assert.equal(body.data.code, 50301);
    assert.equal(body.data.message, '服务暂不可用，请稍后重试。');
    assert(!/N_MEDIA|DESCRIPTION|Oracle|SELECT|migration/i.test(body.data.message));
    assert.equal(f.db.calls.filter(call => /^(CREATE|ALTER|DROP)\b/.test(call.sql)).length, 0);
    assert.equal(f.db.calls.filter(call => call.sql.startsWith('UPDATE n_post_stats')).length, 0);
  } finally {await f.close();}
});

test('post list preserves 503 when a returned item needs an unavailable media schema', async () => {
  const f = await fixture({missingMediaSchema: true});
  try {
    const response = await f.request('/api/v2/posts');
    const body = await response.json();
    assert.equal(response.status, 503);
    assert.equal(body.data.code, 50301);
    assert.equal(f.db.calls.filter(call => /^(CREATE|ALTER|DROP|UPDATE n_post_stats)\b/.test(call.sql)).length, 0);
  } finally {await f.close();}
});

test('personal modes, following/mentions and non-GET methods require authentication', async () => {
  const f = await fixture();
  try {
    for (const url of ['/api/v2/users/me/posts', '/api/v2/users/me/bookmarks', '/api/v2/users/me/likes', '/isolated/me', '/isolated/bookmarks', '/isolated/likes', '/api/v2/posts?timeline=following', '/api/v2/posts?timeline=mentions', '/api/v2/groups/1/posts']) assert.equal((await f.request(url)).status, 401, url);
    for (const [url, method] of [['/api/v2/posts', 'POST'], ['/api/v2/posts/1', 'PUT'], ['/api/v2/posts/1', 'DELETE'], ['/api/v2/posts/1', 'HEAD']]) assert.equal((await f.request(url, {}, method)).status, 401);
    assert.equal(f.db.calls.length, 0);
  } finally {await f.close();}
});

test('valid Cookie/Bearer access enables following, mentions and personal filters with matching counts', async () => {
  const f = await fixture();
  try {
    for (const headers of [{authorization: `Bearer ${access()}`}, {cookie: `access_token=${access()}`}]) {
      for (const [url, ids] of [['/api/v2/posts?timeline=following', [4, 3, 1]], ['/api/v2/posts?timeline=mentions', [4]], ['/api/v2/users/me/posts', [5]], ['/api/v2/users/me/bookmarks', [1]], ['/api/v2/users/me/likes', [7]]]) {
        const response = await f.request(url, headers); assert.equal(response.status, 200, url);
        const body = await response.json(); assert.deepEqual(body.data.map(post => post.post_id), ids); assert.equal(body.meta.total, ids.length);
      }
    }
    const queries = f.db.calls.filter(call => call.sql.includes('f.following_id = v.author_id'));
    assert.equal(queries.length, 4); assert.ok(queries.every(call => call.sql.includes("f.status = 'active'") && call.binds.viewer_id === 1));
  } finally {await f.close();}
});

test('supplied malformed, expired, wrong-type or incomplete tokens are never treated as anonymous or trusted', async () => {
  const f = await fixture();
  try {
    for (const token of ['invalid', access({}, {expiresIn: -1}), access({type: 'refresh'}), access({sessionId: null}), access({jti: null}), access({userId: 1.5})]) {
      for (const url of ['/api/v2/posts', '/api/v2/posts?timeline=following']) assert.equal((await f.request(url, {authorization: `Bearer ${token}`})).status, 401);
    }
    assert.equal((await f.request('/api/v2/posts', {cookie: 'access_token=invalid', authorization: `Bearer ${access()}`})).status, 401);
    assert.equal(f.db.calls.filter(call => call.sql.includes('FROM v_post_feed_item')).length, 0);
  } finally {await f.close();}
});

for (const options of [{revoked: true}, {expiredSession: true}, {failSession: true}]) {
  test(`invalid stored session does not assign privileged viewer: ${JSON.stringify(options)}`, async () => {
    const f = await fixture(options);
    try {
      for (const url of ['/api/v2/posts', '/api/v2/posts?timeline=following', '/api/v2/users/me/posts']) assert.equal((await f.request(url, {authorization: `Bearer ${access()}`})).status, 401);
      assert.equal(f.db.calls.filter(call => call.sql.includes('FROM v_post_feed_item')).length, 0);
    } finally {await f.close();}
  });
}
