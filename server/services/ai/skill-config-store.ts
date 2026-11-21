import type {H3Event} from 'h3';
import oracledb from 'oracledb';
import {requireFeatureSchema} from '~/server/database/readiness';
import {v2Auth} from '~/server/utils/v2';
import {SkillRegistry} from './skill-selection';

/** Authenticated, uncached read. Missing or corrupt configuration enables nothing. */
export async function loadSkillRegistry(event:H3Event,connection:oracledb.Connection):Promise<{generation:number;registry:SkillRegistry}> {
  return readSkillRegistry(event,connection,false);
}

/** Caller owns the transaction and must commit or roll back promptly. Never hold this lock during inference. */
export async function lockSkillRegistry(event:H3Event,connection:oracledb.Connection):Promise<{generation:number;registry:SkillRegistry}> {
  return readSkillRegistry(event,connection,true);
}

async function readSkillRegistry(event:H3Event,connection:oracledb.Connection,lock:boolean):Promise<{generation:number;registry:SkillRegistry}> {
  v2Auth(event);
  try {
    await requireFeatureSchema(connection,'ai-skills');
    const result=await connection.execute<{GENERATION:unknown;ENABLED_IDS:unknown}>(
      `SELECT generation, enabled_ids FROM n_ai_skill_config WHERE singleton_id = :singleton_id${lock?' FOR UPDATE NOWAIT':''}`,
      {singleton_id:1},{outFormat:oracledb.OUT_FORMAT_OBJECT}
    );
    if(result.rows?.length!==1) throw new Error();
    const row=result.rows[0];
    if(!row || typeof row.GENERATION!=='number' || !Number.isSafeInteger(row.GENERATION) || row.GENERATION<1 || row.GENERATION>999_999_999_999_999 || typeof row.ENABLED_IDS!=='string' || Buffer.byteLength(row.ENABLED_IDS,'utf8')>512) throw new Error();
    return {generation:row.GENERATION,registry:new SkillRegistry(JSON.parse(row.ENABLED_IDS))};
  } catch {throw new Error('SKILL_CONFIG_UNAVAILABLE')}
}
