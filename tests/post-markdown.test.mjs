import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { build } from 'esbuild';
import { renderPostMarkdown } from '../app/utils/render-post-markdown.ts';

const { sql } = JSON.parse(readFileSync(new URL('../specifications/requirements/post-markdown.json', import.meta.url), 'utf8'));
const compiled = await build({
  stdin: {contents:`export * from './server/services/v2/post-markdown';
    export {markdownExcerpt,validMarkdownBody} from './app/utils/post-markdown';`,
    resolveDir:fileURLToPath(new URL('../',import.meta.url))},
  bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'markdown-oracle-fixture',setup(builder) {
    const deps={
      oracledb:`export default {OUT_FORMAT_OBJECT:4002,STRING:2001};`,
      '~/server/utils/v2':`const fail=statusCode=>{throw Object.assign(new Error(),{statusCode});};
        export const v2BadRequest=()=>fail(400),v2ServerError=()=>fail(500),v2Execute=(db,query,binds,commit)=>db.write(query,binds,commit);`,
      '~/server/utils/auth-entry-errors':`export const v2ServiceUnavailable=()=>{throw Object.assign(new Error(),{statusCode:503});};`,
      './direct-media-links':`export const isMissingDirectExtras=e=>e?.code==='ORA-00942';
        export const hasNoDirectExtrasTable=(db,query)=>db.absent(query);`,
    };
    builder.onResolve({filter:/.*/},({path})=>Object.hasOwn(deps,path)?{path,namespace:'fixture'}:undefined);
    builder.onLoad({filter:/.*/,namespace:'fixture'},({path})=>({contents:deps[path]}));
  }}],
});
const api=await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

test('ordinary and group Markdown preserve raw text and use the caller transaction',async()=>{
  const posts=new Map(), groups=new Map();
  const db={
    write(query, binds, commit) {
      assert.equal(commit,false);
      if (query===sql.insert) { (binds.group_post_id===null ? posts : groups).set(binds.post_id??binds.group_post_id,binds.markdown_body);return 1; }
      if (query===sql.remove) return Number(posts.delete(binds.post_id));
      assert.equal(query,sql.update);
      if (!posts.has(binds.post_id)) return 0;
      posts.set(binds.post_id,binds.markdown_body);return 1;
    },
    execute(query,binds) {
      assert.equal(query,sql.read);
      const value=(binds.is_group ? groups : posts).get(binds.post_id);
      return {rows:value===undefined ? [] : [{MARKDOWN_BODY:value}]};
    },
  };
  const raw='  # Heading\n\n```js\n  const value = 42;\n```\n';
  assert.equal(api.readPostMarkdownInput(raw),raw);
  await api.attachPostMarkdown(db,'post',25,raw);
  await api.attachPostMarkdown(db,'group',25,'**Group**');
  assert.equal(await api.readPostMarkdown(db,'post',25),raw);
  assert.equal(await api.readPostMarkdown(db,'group',25),'**Group**');
  await api.updatePostMarkdown(db,25,'# Replacement');
  assert.equal(await api.readPostMarkdown(db,'post',25),'# Replacement');
  await api.updatePostMarkdown(db,25,null);
  assert.equal(await api.readPostMarkdown(db,'post',25),undefined);
});

test('body limit uses UTF-8 bytes and legacy post reads tolerate a missing table',async()=>{
  const unavailable={execute(){throw Object.assign(new Error(),{code:'ORA-00942'});},absent(query){assert.equal(query,sql.present);return true;}};
  assert.equal(await api.readPostMarkdown(unavailable,'post',25),undefined);
  assert.throws(()=>api.readPostMarkdownInput('中文'.repeat(3000)),{statusCode:400});
  assert(!api.validMarkdownBody('中文'.repeat(3000)));
  assert.equal(api.markdownExcerpt('猫'.repeat(500)).length,280);
});

test('Web retains formatted text and highlighted code under an explicit allowlist',()=>{
  const source=['# Heading','', '**Strong** [docs](https://example.com) [local](file:///fixture.txt)', '',
    '<iframe>Raw text</iframe>', '', '![image alt](https://example.com/image.jpg)', '',
    '```javascript','const value = "text";','```'].join('\n');
  const output=renderPostMarkdown(source);
  assert.match(output,/<h1>Heading<\/h1>/);
  assert.match(output,/<strong>Strong<\/strong>/);
  assert.match(output,/<a href="https:\/\/example\.com"[^>]* rel="noopener noreferrer">docs<\/a>/);
  assert.match(output,/<span class="hljs-keyword">const<\/span>/);
  assert.match(output,/image alt/);
  assert.doesNotMatch(output,/<iframe|<img|href="file:|onload=/i);
});
