import type { PostVM } from '../types/posts';

type PatchPost = (id: number, change: (post: PostVM) => PostVM) => void;

/** Restore only the optimistic count if a refresh hasn't already replaced it. */
export function beginRepost(id: number, patch: PatchPost) {
  let previous: number | undefined;
  patch(id, post => {
    previous = post.counts.retweets;
    return { ...post, counts: { ...post.counts, retweets: previous + 1 } };
  });
  return () => patch(id, post => previous !== undefined && post.counts.retweets === previous + 1
    ? { ...post, counts: { ...post.counts, retweets: previous } }
    : post);
}
