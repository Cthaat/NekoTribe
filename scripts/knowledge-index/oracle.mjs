import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { loadMaintenanceRuntime } from '../ai-public-terms-maintenance.mjs';
import { loadOracleDriver } from '../migrate-db.mjs';
import { maxSourceId } from './config.mjs';

const root = fileURLToPath(new URL('../../',import.meta.url));
const PAGE = 100;
const sources = [
  ['post',`SELECT p.post_id AS source_id,p.post_id AS post_id,p.content FROM n_posts p
    JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1
    WHERE p.post_id>:after_id AND p.post_id<=:max_id AND p.visibility='public' AND p.is_deleted=0
    AND DBMS_LOB.GETLENGTH(p.content) BETWEEN 1 AND 65536
    ORDER BY p.post_id FETCH FIRST 100 ROWS ONLY`],
  ['comment',`SELECT c.comment_id AS source_id,p.post_id,c.content FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id
    JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1
    JOIN n_users comment_author ON comment_author.user_id=c.user_id AND comment_author.is_active=1
    WHERE c.comment_id>:after_id AND c.comment_id<=:max_id AND p.post_id BETWEEN 1 AND :max_id
    AND c.is_deleted=0 AND p.visibility='public' AND p.is_deleted=0
    AND DBMS_LOB.GETLENGTH(c.content) BETWEEN 1 AND 65536
    ORDER BY c.comment_id FETCH FIRST 100 ROWS ONLY`],
  ['group_post',`SELECT p.post_id AS source_id,p.post_id AS post_id,p.content FROM n_group_posts p
    JOIN n_groups g ON g.group_id=p.group_id AND g.privacy='public' AND g.is_active=1 AND g.is_deleted=0
    JOIN n_users a ON a.user_id=p.author_id AND a.is_active=1
    WHERE p.post_id>:after_id AND p.post_id<=:max_id AND p.group_id BETWEEN 1 AND :max_id
    AND p.is_deleted=0
    ORDER BY p.post_id FETCH FIRST 100 ROWS ONLY`],
  ['group_comment',`SELECT c.comment_id AS source_id,p.post_id,c.content FROM n_group_comments c
    JOIN n_group_posts p ON p.post_id=c.post_id AND p.is_deleted=0
    JOIN n_groups g ON g.group_id=p.group_id AND g.privacy='public' AND g.is_active=1 AND g.is_deleted=0
    JOIN n_users a ON a.user_id=p.author_id AND a.is_active=1
    JOIN n_users ca ON ca.user_id=c.author_id AND ca.is_active=1
    WHERE c.comment_id>:after_id AND c.comment_id<=:max_id AND p.post_id BETWEEN 1 AND :max_id
    AND p.group_id BETWEEN 1 AND :max_id AND c.is_deleted=0
    ORDER BY c.comment_id FETCH FIRST 100 ROWS ONLY`],
];
const validId = value => Number.isSafeInteger(value) && value >= 1 && value <= maxSourceId;

export async function* readPublicSources(connection, options, signal) {
  for (const [kind,sql] of sources) {
    let after = 0;
    let page;
    do {
      signal?.throwIfAborted();
      page = (await connection.execute(sql,{after_id:after,max_id:maxSourceId},options)).rows;
      signal?.throwIfAborted();
      if (page.length > PAGE) throw Error('INVALID_SOURCE_PAGE');
      for (const {SOURCE_ID:id,POST_ID:post,CONTENT:content} of page) {
        if (!validId(id) || id <= after || !validId(post) ||
            ((kind === 'post' || kind === 'group_post') && post !== id) ||
            typeof content !== 'string' || !content.isWellFormed()) throw Error('INVALID_SOURCE_ROW');
        after = id;
        if (!content || Buffer.byteLength(content) > 65536) continue;
        const version = createHash('sha256').update(`neko-ai-source-v1\0${kind}\0${id}\0${post}\0`).update(content).digest('hex');
        yield {kind,id,version,content};
      }
    } while (page.length === PAGE);
  }
}

async function* publishedTerms(connection, options) {
  const result = await connection.execute('SELECT catalog_digest, enabled FROM n_ai_terms_active WHERE singleton_id=1',{},options);
  if (result.rows.length > 1) throw Error('TERMS_AUTHORITY_INVALID');
  const row = result.rows[0];
  if (!row || row.ENABLED === 0) return;
  const runtime = await loadMaintenanceRuntime();
  const catalog = JSON.parse(await readFile(new URL('../../specifications/requirements/ai-public-terms-catalog.json', import.meta.url),'utf8'));
  if (row.ENABLED !== 1 || row.CATALOG_DIGEST !== runtime.termsCatalogDigest(catalog)) throw Error('TERMS_AUTHORITY_MISMATCH');
  for (const term of runtime.parseTermsCatalog(catalog)) {
    const content = [term.title,...term.blocks].join('\n');
    if (Buffer.byteLength(content) <= 65536) yield {kind:'terms',id:term.id,version:term.version,content};
  }
}

export async function checkPublicSources(connection, options, signal) {
  const results = [];
  for (const [source, sql] of sources) {
    signal?.throwIfAborted();
    try {
      // Parse the exact snapshot query against the deployment schema without fetching content.
      await connection.execute(`SELECT * FROM (${sql}) WHERE 1=0`, {after_id:0,max_id:maxSourceId}, options);
      signal?.throwIfAborted();
      results.push({source,ok:true});
    } catch {
      signal?.throwIfAborted();
      results.push({source,ok:false,code:'SOURCE_READ_UNAVAILABLE'});
    }
  }
  try {
    let published = false;
    for await (const _ of publishedTerms(connection, options)) {
      signal?.throwIfAborted();
      published = true;
    }
    signal?.throwIfAborted();
    results.push({source:'terms',ok:true,published});
  } catch (error) {
    signal?.throwIfAborted();
    const expected = ['TERMS_AUTHORITY_INVALID','TERMS_AUTHORITY_MISMATCH'];
    const code = expected.includes(error?.message) ? error.message : 'SOURCE_READ_UNAVAILABLE';
    results.push({source:'terms',ok:false,code});
  }
  return {ready:results.every(result => result.ok),results};
}

async function openReadOnlySnapshot(signal) {
  signal?.throwIfAborted();
  const get = name => process.env[`AI_INDEX_${name}`];
  const user = get('ORACLE_USER'), password = get('ORACLE_PASSWORD'), connectString = get('ORACLE_CONNECT');
  if (!user || !password || !connectString) throw Error('ORACLE_CONFIG_REQUIRED');
  const module = await loadOracleDriver(root);
  signal?.throwIfAborted();
  const oracle = module.default ?? module;
  const connection = await oracle.getConnection({user,password,connectString});
  connection.callTimeout = 15000;
  const options = {outFormat:oracle.OUT_FORMAT_OBJECT,fetchTypeHandler:metadata => metadata.name === 'CONTENT' ? {type:oracle.STRING} : undefined};
  try {
    signal?.throwIfAborted();
    await connection.execute('SET TRANSACTION READ ONLY');
    signal?.throwIfAborted();
    return {connection,options};
  } catch (error) {
    await connection.close().catch(() => {});
    throw error;
  }
}

export async function checkOracleSources({signal} = {}) {
  const {connection,options} = await openReadOnlySnapshot(signal);
  try {
    return await checkPublicSources(connection,options,signal);
  } finally {
    await connection.close();
  }
}

export async function* oracleSnapshot({signal} = {}) {
  const {connection,options} = await openReadOnlySnapshot(signal);
  try {
    for await (const terms of publishedTerms(connection,options)) {
      signal?.throwIfAborted();
      yield terms;
    }
    yield* readPublicSources(connection, options, signal);
  } finally {
    await connection.close();
  }
}
