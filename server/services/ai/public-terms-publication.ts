import type oracledb from 'oracledb';
import {requireFeatureSchema} from '~/server/database/readiness';
import {termsCatalogDigest} from './public-terms-authority';

type Change = {action:'publish';expectedGeneration:number;catalog:unknown} | {action:'disable';expectedGeneration:number};
type Result = {generation:number;digest:string;enabled:true} | {generation:number;enabled:false};
const maxGeneration=999_999_999_999_999;

/**
 * Privileged maintenance operation on a dedicated connection with no prior work.
 * The caller authenticates and authorizes the operator; never expose directly to HTTP.
 */
export async function changeTermsAuthority(connection:oracledb.Connection,change:Change):Promise<Result> {
  if(!change || !['publish','disable'].includes(change.action) || !Number.isSafeInteger(change.expectedGeneration) || change.expectedGeneration<0 || change.expectedGeneration>=maxGeneration || (change.action==='disable' && change.expectedGeneration===0)) throw new Error('TERMS_AUTHORITY_INVALID_INPUT');
  let digest:string|undefined;
  if(change.action==='publish') {
    try {digest=termsCatalogDigest(change.catalog)} catch {throw new Error('TERMS_AUTHORITY_INVALID_INPUT')}
  }
  try {await requireFeatureSchema(connection,'ai-terms')} catch {throw new Error('TERMS_AUTHORITY_WRITE_FAILED')}
  let result:oracledb.Result<unknown>;
  try {
    if(change.action==='publish' && change.expectedGeneration===0) {
      result=await connection.execute('INSERT INTO n_ai_terms_active (singleton_id,catalog_digest,generation,enabled) VALUES (1,:digest,1,1)',{digest},{autoCommit:false});
    } else if(change.action==='publish') {
      result=await connection.execute('UPDATE n_ai_terms_active SET catalog_digest=:digest,generation=generation+1,enabled=1,updated_at=CURRENT_TIMESTAMP WHERE singleton_id=1 AND generation=:expected_generation',{digest,expected_generation:change.expectedGeneration},{autoCommit:false});
    } else {
      result=await connection.execute('UPDATE n_ai_terms_active SET generation=generation+1,enabled=0,updated_at=CURRENT_TIMESTAMP WHERE singleton_id=1 AND generation=:expected_generation',{expected_generation:change.expectedGeneration},{autoCommit:false});
    }
  } catch {
    try {await connection.rollback()} catch { /* dedicated connection must be discarded */ }
    throw new Error('TERMS_AUTHORITY_WRITE_FAILED');
  }
  if(result.rowsAffected!==1) {
    try {await connection.rollback()} catch {throw new Error('TERMS_AUTHORITY_WRITE_FAILED')}
    throw new Error('TERMS_AUTHORITY_CONFLICT');
  }
  // A failed commit can already have reached Oracle; never retry automatically.
  try {await connection.commit()} catch {throw new Error('TERMS_AUTHORITY_COMMIT_UNCERTAIN')}
  return change.action==='publish' && digest!==undefined
    ? {generation:change.expectedGeneration+1,digest,enabled:true}
    : {generation:change.expectedGeneration+1,enabled:false};
}
