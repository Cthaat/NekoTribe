import type { PostVM, UpdatePostFormVM } from '@/types/posts';
import type { V2PostVisibility } from '@/types/v2';
import { markdownExcerpt } from './post-markdown';

export interface PostEditForm {
  content: string;
  markdown?: boolean;
  visibility: V2PostVisibility;
  language: string;
  location: string;
  tags: string;
}

export function postEditTarget(value: unknown): number | null {
  if (typeof value !== 'string' || !/^[1-9]\d*$/.test(value)) return null;
  const id = Number(value);
  return Number.isSafeInteger(id) ? id : null;
}

export function postEditPatch(initial: PostEditForm, draft: PostEditForm): UpdatePostFormVM {
  const patch: UpdatePostFormVM = {};
  if (draft.content !== initial.content || !!draft.markdown !== !!initial.markdown) {
    patch.content = draft.markdown ? markdownExcerpt(draft.content) : draft.content;
    if (draft.markdown) patch.markdown = draft.content;
    else if (initial.markdown) patch.markdown = null;
  }
  if (draft.visibility !== initial.visibility) patch.visibility = draft.visibility;
  if (draft.language !== initial.language) patch.language = draft.language;
  if (draft.location !== initial.location) patch.location = draft.location;
  if (draft.tags !== initial.tags || draft.content !== initial.content) {
    const tags = (form: PostEditForm) => [...new Set([
      ...Array.from(form.content.matchAll(/#([\p{L}\p{N}_]+)/gu), match => match[1] ?? ''),
      ...form.tags.split(/[\s,，]+/u)
    ].map(tag => tag.trim().replace(/^#+/, '').toLowerCase().slice(0, 32)).filter(Boolean))].slice(0, 8);
    const next = tags(draft);
    if (draft.tags !== initial.tags || JSON.stringify(next) !== JSON.stringify(tags(initial))) patch.tagNames = next;
  }
  return patch;
}

export function postEditMediaIds(
  media: PostVM['media'],
  removed: ReadonlySet<number>,
  removePrivate: boolean
): number[] | undefined {
  const retained = media.filter(item =>
    !removed.has(item.id) && (!removePrivate || item.privateFileName === undefined));
  return retained.length === media.length ? undefined : retained.map(item => item.id);
}

export function postEditOwned(post: PostVM, postId: number, ownerId: number): boolean {
  return ownerId > 0 && post.id === postId && post.author.id === ownerId;
}
