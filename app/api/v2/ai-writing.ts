import { v2RequestData } from './client';
import type { WritingApi, WritingConversation, WritingMessage, WritingPage } from '@/services/ai-writing-controller';

const base='/api/v2/ai/conversations';
const path=(id:string)=>`${base}/${encodeURIComponent(id)}`;

export const writingApi: WritingApi = {
  create: () => v2RequestData<WritingConversation,{purpose:string}>(base,{method:'POST',body:{purpose:'writing'}}),
  append: (id,content) => v2RequestData<unknown,{content:string}>(`${path(id)}/messages`,{method:'POST',body:{content}}),
  generate: id => v2RequestData<unknown>(`${path(id)}/generate`,{method:'POST'}),
  messages: (id,after) => v2RequestData<WritingMessage[],undefined,{after_sequence:number;limit:number}>(`${path(id)}/messages`,{query:{after_sequence:after,limit:50}}),
  list: after => v2RequestData<WritingPage,undefined,{after_id?:string;limit:number}>(base,{query:{...(after ? {after_id:after}:{}),limit:50}}),
  remove: id => v2RequestData<null>(path(id),{method:'DELETE'})
};
