export const groupBookmarkKey = (account: number, group: number, post: number) =>
  `nekotribe.group-bookmark.${account}.${group}.${post}`;

export function toggleGroupBookmark(marks: Record<string, boolean>, key: string, storage: () => Storage) {
  const before = !!marks[key];
  marks[key] = !before;
  try {
    if (before) storage().removeItem(key);
    else storage().setItem(key, '1');
  } catch (error) {
    marks[key] = before;
    throw error;
  }
}
