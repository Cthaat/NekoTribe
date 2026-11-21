import type oracledb from 'oracledb';
import writeContract from '../../../specifications/requirements/ai-skill-config-write.json';
import {requireFeatureSchema} from '~/server/database/readiness';
import {SkillRegistry} from './skill-selection';

/**
 * Privileged maintenance operation on a dedicated, otherwise idle connection.
 * Its caller must authenticate the operator; this function is not an HTTP endpoint.
 */
export async function publishSkillConfig(connection:oracledb.Connection,input:{expectedGeneration:number;enabled:unknown}):Promise<{generation:number;enabled:string[]}> {
  if(!input || !Number.isSafeInteger(input.expectedGeneration) || input.expectedGeneration<0 || input.expectedGeneration>=writeContract.maxGeneration) throw new Error('SKILL_CONFIG_INVALID_INPUT');
  let enabled:string[];
  try {
    new SkillRegistry(input.enabled);
    if(!Array.isArray(input.enabled)) throw new Error();
    enabled=[...input.enabled].sort();
  } catch {throw new Error('SKILL_CONFIG_INVALID_INPUT')}
  const encoded=JSON.stringify(enabled);
  if(Buffer.byteLength(encoded,'utf8')>512) throw new Error('SKILL_CONFIG_INVALID_INPUT');
  try {await requireFeatureSchema(connection,'ai-skills')} catch {throw new Error('SKILL_CONFIG_WRITE_FAILED')}
  let result:oracledb.Result<unknown>;
  try {
    result=input.expectedGeneration===0
      ? await connection.execute(writeContract.queries.insert,{enabled_ids:encoded},{autoCommit:false})
      : await connection.execute(writeContract.queries.update,{enabled_ids:encoded,expected_generation:input.expectedGeneration},{autoCommit:false});
  } catch (error) {
    try {await connection.rollback()} catch {throw new Error('SKILL_CONFIG_WRITE_FAILED')}
    if(input.expectedGeneration===0 && typeof error==='object' && error!==null &&
      ('errorNum' in error && error.errorNum===1 || 'code' in error && error.code==='ORA-00001')) {
      throw new Error('SKILL_CONFIG_CONFLICT');
    }
    throw new Error('SKILL_CONFIG_WRITE_FAILED');
  }
  if(result.rowsAffected!==1) {
    try {await connection.rollback()} catch {throw new Error('SKILL_CONFIG_WRITE_FAILED')}
    throw new Error('SKILL_CONFIG_CONFLICT');
  }
  try {await connection.commit()} catch {throw new Error('SKILL_CONFIG_COMMIT_UNCERTAIN')}
  return {generation:input.expectedGeneration+1,enabled};
}
