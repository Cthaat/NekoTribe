import { v2RequestData } from './client';
import { getAiAvailability } from './ai-availability';
import { readAiMessagePage } from './ai-writing';
import { validateAssistantReceipt, validateUserReceipt } from '../../services/ai-writing-controller';
import type { WritingApi, WritingConversation, WritingPage } from '@/services/ai-writing-controller';

const base='/api/v2/ai/conversations';
const path=(id:string)=>`${base}/${encodeURIComponent(id)}`;
export type KnowledgeScope = 'public' | 'personal' | 'group';

export const knowledgeApi: WritingApi = {
  availability: getAiAvailability,
  create: (signal,title) => v2RequestData<WritingConversation,{purpose:string;title?:string}>(base,{signal,method:'POST',body:{purpose:'knowledge',...(title ? {title} : {})}}),
  read: (id,signal) => v2RequestData<WritingConversation>(path(id),{signal}),
  append: async (id,content,signal) => validateUserReceipt(
    await v2RequestData<unknown,{content:string}>(`${path(id)}/messages`,{signal,method:'POST',body:{content}}), id),
  generate: async (id,phrase,signal,selectSkill,expectedSequence,onDelta) => {
    const result = await v2RequestData<{status: string; message: unknown},{search_phrase?:string;skill_id?:'knowledge-answer';expected_sequence?:number}>(
      `${path(id)}/knowledge-generate`,{
        signal,method:'POST',
        ...(phrase !== undefined || selectSkill || expectedSequence !== undefined ? {body:{
          ...(phrase !== undefined ? {search_phrase:phrase} : {}),
          ...(selectSkill ? {skill_id:'knowledge-answer'} : {}),
          ...(expectedSequence !== undefined ? {expected_sequence:expectedSequence} : {})
        }} : {}),
        ...(onDelta ? {onDelta} : {})
      });
    if (result?.status === 'generated') validateAssistantReceipt(result.message, id, expectedSequence);
    else if (result?.status !== 'insufficient_evidence' || result.message !== null) throw Error('invalid knowledge receipt');
    return result;
  },
  messages: readAiMessagePage,
  list: (after,signal) => v2RequestData<WritingPage,undefined,{after_id?:string;limit:number;purpose:string}>(base,{signal,query:{...(after ? {after_id:after}:{}),limit:50,purpose:'knowledge'}}),
  remove: (id,signal) => v2RequestData<null>(path(id),{signal,method:'DELETE'})
};

export function scopedKnowledgeApi(scope: KnowledgeScope, groupId?: number): WritingApi {
  const filter = { knowledge_scope: scope, ...(scope === 'group' && groupId !== undefined ? { group_id: groupId } : {}) };
  return {
    ...knowledgeApi,
    read: async (id, signal) => {
      const record = await v2RequestData<WritingConversation & {knowledge_scope?: KnowledgeScope; group_id?:number | null}>(path(id), {signal});
      if ((record.knowledge_scope ?? 'public') !== scope || (record.group_id ?? undefined) !== groupId) {
        throw Object.assign(new Error('Conversation outside selected knowledge scope'), {statusCode:404});
      }
      return record;
    },
    create: (signal, title) => v2RequestData<WritingConversation, {purpose:'knowledge';knowledge_scope:KnowledgeScope;group_id?:number;title?:string}>(
      base, {signal,method:'POST',body:{purpose:'knowledge',...filter,...(title ? {title} : {})}}
    ),
    list: (after, signal) => v2RequestData<WritingPage, undefined, {purpose:'knowledge';knowledge_scope:KnowledgeScope;group_id?:number;limit:number;after_id?:string}>(
      base,{signal,query:{purpose:'knowledge',...filter,limit:50,...(after ? {after_id:after} : {})}}
    )
  };
}
