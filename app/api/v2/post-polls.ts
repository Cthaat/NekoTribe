import type { V2CreatePostPoll, V2PostPoll } from '@/types/v2';
import { v2RequestData } from './client';

function pollPath(postId: number, groupId?: number): string {
  return groupId === undefined ? `/api/v2/posts/${postId}/poll` : `/api/v2/groups/${groupId}/posts/${postId}/poll`;
}

function validatePoll(poll: V2PostPoll, expected: number): V2PostPoll {
  if (!poll || poll.poll_id !== expected || typeof poll.closed !== 'boolean' || !Array.isArray(poll.options) ||
      !Array.isArray(poll.my_option_ids)) throw new Error('Invalid post poll response');
  return poll;
}

export function confirmsCreatedPoll(poll: V2PostPoll | undefined, submitted: V2CreatePostPoll): boolean {
  return !!poll && Number.isSafeInteger(poll.poll_id) && poll.poll_id > 0 && poll.multiple === submitted.multiple &&
    Date.parse(poll.closes_at) === Date.parse(submitted.closes_at) && Array.isArray(poll.options) &&
    poll.options.length === submitted.options.length &&
    submitted.options.every((option,index) => poll.options[index]?.option_id === index+1 && poll.options[index]?.text === option.trim());
}

export async function v2GetPostPoll(postId: number, groupId: number | undefined, expected: number, signal: AbortSignal) {
  return validatePoll(await v2RequestData<V2PostPoll>(pollPath(postId,groupId),{signal}),expected);
}

export async function v2VotePostPoll(postId: number, groupId: number | undefined, expected: number, choices: number[], signal: AbortSignal) {
  const poll = validatePoll(await v2RequestData<V2PostPoll,{option_ids:number[]}>(`${pollPath(postId,groupId)}/vote`,
    {method:'POST',body:{option_ids:choices},signal}),expected);
  if (poll.my_option_ids.length !== choices.length || !choices.every(id=>poll.my_option_ids.includes(id))) throw new Error('Invalid vote receipt');
  return poll;
}
