import {createHash} from 'node:crypto';
import type {H3Event} from 'h3';
import oracledb from 'oracledb';
import {requireFeatureSchema} from '~/server/database/readiness';
import {v2Auth} from '~/server/utils/v2';
import {parseTermsCatalog} from './public-terms-source';

/** Hash the validated, canonically ordered catalog, independently of JSON ordering. */
export function termsCatalogDigest(raw:unknown):string {
  const hash=createHash('sha256').update('neko-ai-terms-catalog-v1\0','utf8');
  for(const row of parseTermsCatalog(raw)) {
    for(const value of [String(row.id),row.version]) hash.update(`${Buffer.byteLength(value,'utf8')}:`,'utf8').update(value,'utf8');
  }
  return hash.digest('hex');
}

/** Read the durable authority for each request; do not fall back to cache or local version. */
export async function readTermsAuthority(event:H3Event,connection:oracledb.Connection,raw:unknown,options:{lock?:boolean}={}):Promise<{digest:string;generation:number}> {
  v2Auth(event);
  try {
    const digest=termsCatalogDigest(raw);
    await requireFeatureSchema(connection,'ai-terms');
    const result=await connection.execute<{CATALOG_DIGEST:unknown;GENERATION:unknown;ENABLED:unknown}>(
      `SELECT catalog_digest, generation, enabled FROM n_ai_terms_active WHERE singleton_id = :singleton_id${options.lock?' FOR UPDATE WAIT 5':''}`,
      {singleton_id:1},{outFormat:oracledb.OUT_FORMAT_OBJECT}
    );
    if(result.rows?.length!==1) throw new Error('invalid authority');
    const row=result.rows[0];
    if(!row || row.CATALOG_DIGEST!==digest || row.ENABLED!==1 || typeof row.GENERATION!=='number' || !Number.isSafeInteger(row.GENERATION) || row.GENERATION<1 || row.GENERATION>999_999_999_999_999) throw new Error('invalid authority');
    return {digest,generation:row.GENERATION};
  } catch {
    throw new Error('TERMS_AUTHORITY_UNAVAILABLE');
  }
}
