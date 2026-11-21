import { v2RequestData } from './client';
import { getAiAvailability } from './ai-availability';
import { validateAssistantReceipt, validateUserReceipt } from '../../services/ai-writing-controller';
import type { WritingApi, WritingConversation, WritingMessage, WritingPage } from '@/services/ai-writing-controller';

const base='/api/v2/ai/conversations';
const path=(id:string)=>`${base}/${encodeURIComponent(id)}`;

export async function readAiMessagePage(
  id: string, after: number, signal?: AbortSignal, before?: number
): Promise<WritingMessage[]> {
  const page = await v2RequestData<unknown,undefined,{after_sequence?:number;before_sequence?:number;limit:number}>(
    `${path(id)}/messages`, {
      signal, query: before === undefined ? {after_sequence:after,limit:50} : {before_sequence:before,limit:50}
    });
  if (!Array.isArray(page) || page.length > 50) throw Error('invalid message page');
  const messageIds = new Set<string>();
  for (const message of page) {
    const row = message as Partial<WritingMessage & { conversation_id: string }> | null;
    if (!row || row.conversation_id !== id || typeof row.message_id !== 'string' ||
        !row.message_id || messageIds.has(row.message_id) ||
        typeof row.sequence_no !== 'number' || !Number.isSafeInteger(row.sequence_no) ||
        row.sequence_no < 1 || row.sequence_no > 9_999_999_999 ||
        (row.role !== 'assistant' && row.role !== 'user') ||
        typeof row.content !== 'string') throw Error('invalid history message');
    messageIds.add(row.message_id);
  }
  return page;
}

export const writingApi: WritingApi = {
  availability: getAiAvailability,
  create: (signal,title) => v2RequestData<WritingConversation,{purpose:string;title?:string}>(base,{signal,method:'POST',body:{purpose:'writing',...(title ? {title} : {})}}),
  read: (id,signal) => v2RequestData<WritingConversation>(path(id),{signal}),
  append: async (id,content,signal) => validateUserReceipt(
    await v2RequestData<unknown,{content:string}>(`${path(id)}/messages`,{signal,method:'POST',body:{content}}), id),
  generate: async (id,_phrase,signal,selectSkill,expectedSequence) => {
    const result = await v2RequestData<unknown,{skill_id?:'writing-draft';expected_sequence?:number}>(
      `${path(id)}/generate`,{signal,method:'POST',...(selectSkill || expectedSequence !== undefined ? {body:{
        ...(selectSkill ? {skill_id:'writing-draft'} : {}),
        ...(expectedSequence !== undefined ? {expected_sequence:expectedSequence} : {})
      }} : {})});
    validateAssistantReceipt(result, id, expectedSequence);
    return result;
  },
  messages: readAiMessagePage,
  list: (after,signal) => v2RequestData<WritingPage,undefined,{after_id?:string;limit:number;purpose:string}>(base,{signal,query:{...(after ? {after_id:after}:{}),limit:50,purpose:'writing'}}),
  remove: (id,signal) => v2RequestData<null>(path(id),{signal,method:'DELETE'})
};
