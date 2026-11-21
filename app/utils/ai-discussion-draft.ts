interface DiscussionPost {
  id: number;
  visibility: string;
  content: string;
}

interface DiscussionComment {
  postId: number;
  content: string;
}

export function discussionDraft(post: DiscussionPost, comments: readonly DiscussionComment[]): string {
  const content = post.content.trim();
  if (post.visibility !== 'public' || !content) return '';
  const encoder = new TextEncoder();
  let bytes = encoder.encode(content).length;
  if (bytes > 16384) return '';
  const parts = [content];
  for (const comment of comments) {
    if (parts.length > 20) break;
    const text = comment.content.trim();
    if (comment.postId !== post.id || !text) continue;
    const size = 2 + encoder.encode(text).length;
    if (bytes + size > 16384) break;
    parts.push(text);
    bytes += size;
  }
  return parts.join('\n\n');
}

const pending = new WeakMap<object, { revision: number; text: string }>();

export function stageDiscussionDraft(app: object, revision: number, text: string): () => void {
  const draft = { revision, text };
  pending.set(app, draft);
  return () => {
    if (pending.get(app) === draft) pending.delete(app);
  };
}

export function takeDiscussionDraft(app: object, revision: number): string {
  const draft = pending.get(app);
  pending.delete(app);
  return draft?.revision === revision ? draft.text : '';
}
