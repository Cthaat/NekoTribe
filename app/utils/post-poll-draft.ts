import type { V2CreatePostPoll } from '@/types/v2';
import policy from '../../specifications/requirements/post-polls.json';

export interface PostPollDraft {
  options: string[];
  multiple: boolean;
  closesLocal: string;
}

export const postPollLimits = {min:policy.min_options,max:policy.max_options};

export function newPostPollDraft(now = Date.now()): PostPollDraft {
  return openPostPollDraft({options:['',''],multiple:false,closes_at:new Date(now + 86_400_000).toISOString()});
}

export function openPostPollDraft(poll: V2CreatePostPoll): PostPollDraft {
  const closes = new Date(poll.closes_at);
  const local = new Date(closes.getTime() - closes.getTimezoneOffset() * 60 * 1000);
  return {options:[...poll.options],multiple:poll.multiple,closesLocal:local.toISOString().slice(0,16)};
}

export function postPollPayload(draft: PostPollDraft | null, now = Date.now()): V2CreatePostPoll | undefined {
  if (!draft) return;
  const options = draft.options.map(item => item.trim());
  if (options.length < postPollLimits.min || options.length > postPollLimits.max || new Set(options).size !== options.length ||
      options.some(option => !option || new TextEncoder().encode(option).length > policy.max_option_bytes)) return;
  const date = new Date(draft.closesLocal);
  if (!Number.isFinite(date.getTime()) || date.getTime() <= now) return;
  return {options,multiple:draft.multiple,closes_at:date.toISOString()};
}
