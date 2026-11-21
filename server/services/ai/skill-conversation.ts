import type {H3Event} from 'h3';
import type oracledb from 'oracledb';
import {v2Auth} from '~/server/utils/v2';
import {authorizeConversationScope,type ConversationScope} from './conversation-access';
import {SkillRegistry,type SkillSelection} from './skill-selection';
import {loadSkillRegistry} from './skill-config-store';

/** Scope must come from a freshly loaded conversation, not client-supplied role claims. */
export async function selectConversationSkill(event:H3Event,connection:oracledb.Connection,registry:SkillRegistry,scope:ConversationScope,skillId:string|null):Promise<SkillSelection> {
  const actor=v2Auth(event);
  const checkedScope:ConversationScope={ownerUserId:scope.ownerUserId,purpose:scope.purpose,groupId:scope.groupId};
  return registry.select({actorId:actor.userId,purpose:checkedScope.purpose,groupId:checkedScope.groupId,skillId},async()=>{
    await authorizeConversationScope(event,connection,checkedScope);
    return true;
  });
}

/** Each request reads the shared configuration; the snapshot is not a lasting grant. */
export async function selectConfiguredConversationSkill(event:H3Event,connection:oracledb.Connection,scope:ConversationScope,skillId:string|null):Promise<{skill:SkillSelection;configGeneration:number}> {
  v2Auth(event);
  const checkedScope:ConversationScope={ownerUserId:scope.ownerUserId,purpose:scope.purpose,groupId:scope.groupId};
  const {registry,generation}=await loadSkillRegistry(event,connection);
  const skill=await selectConversationSkill(event,connection,registry,checkedScope,skillId);
  return {skill,configGeneration:generation};
}
