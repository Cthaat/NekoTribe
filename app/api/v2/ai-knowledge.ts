import { v2RequestData } from './client';
import { getAiAvailability } from './ai-availability';
import { readAiMessagePage } from './ai-writing';
import { validateAssistantReceipt, validateUserReceipt } from '../../services/ai-writing-controller';
import type { WritingApi, WritingConversation, WritingPage } from '@/services/ai-writing-controller';

const base='/api/v2/ai/conversations';
const path=(id:string)=>`${base}/${encodeURIComponent(id)}`;

export const knowledgeApi: WritingApi = {
  availability: getAiAvailability,
  create: (signal,title) => v2RequestData<WritingConversation,{purpose:string;title?:string}>(base,{signal,method:'POST',body:{purpose:'knowledge',...(title ? {title} : {})}}),
  read: (id,signal) => v2RequestData<WritingConversation>(path(id),{signal}),
  append: async (id,content,signal) => validateUserReceipt(
    await v2RequestData<unknown,{content:string}>(`${path(id)}/messages`,{signal,method:'POST',body:{content}}), id),
  generate: async (id,phrase,signal,selectSkill,expectedSequence) => {
    const result = await v2RequestData<{status: string; message: unknown},{search_phrase?:string;skill_id?:'knowledge-answer';expected_sequence?:number}>(
      `${path(id)}/knowledge-generate`,{
        signal,method:'POST',
        ...(phrase !== undefined || selectSkill || expectedSequence !== undefined ? {body:{
          ...(phrase !== undefined ? {search_phrase:phrase} : {}),
          ...(selectSkill ? {skill_id:'knowledge-answer'} : {}),
          ...(expectedSequence !== undefined ? {expected_sequence:expectedSequence} : {})
        }} : {})
      });
    if (result?.status === 'generated') validateAssistantReceipt(result.message, id, expectedSequence);
    else if (result?.status !== 'insufficient_evidence' || result.message !== null) throw Error('invalid knowledge receipt');
    return result;
  },
  messages: readAiMessagePage,
  list: (after,signal) => v2RequestData<WritingPage,undefined,{after_id?:string;limit:number;purpose:string}>(base,{signal,query:{...(after ? {after_id:after}:{}),limit:50,purpose:'knowledge'}}),
  remove: (id,signal) => v2RequestData<null>(path(id),{signal,method:'DELETE'})
};
