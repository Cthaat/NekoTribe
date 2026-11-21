export function isGroupCommentNotice(notice: { type: string; resourceType: string | null }): boolean {
  return notice.type === 'group_comment' || notice.resourceType === 'group_comment';
}

export function isGroupPostNotice(notice: { type: string; resourceType: string | null }): boolean {
  return isGroupCommentNotice(notice) || notice.type === 'group_post' || notice.resourceType === 'group_post';
}

function safeId(value: unknown): number | null {
  const id = typeof value === 'string' && value.trim() === value &&
    /^[1-9][0-9]{0,15}$/.test(value) ? Number(value) : value;
  return typeof id === 'number' && Number.isSafeInteger(id) && id > 0 ? id : null;
}

export function groupNotificationQuery(
  notice: { type: string; resourceType: string | null; resourceId: number | null },
  metadata: Record<string, unknown>
): Record<string, string> | null {
  if (!isGroupPostNotice(notice)) return null;
  const comment = isGroupCommentNotice(notice);
  const groupId = safeId(metadata.group_id);
  const postId = safeId(metadata.post_id) ??
    (!comment && notice.resourceType === 'group_post' ? safeId(notice.resourceId) : null);
  if (groupId === null || postId === null) return null;
  const cited = comment ? safeId(metadata.comment_id) : null;
  const resource = comment && notice.resourceType === 'group_comment' ? safeId(notice.resourceId) : null;
  if (resource !== null && cited !== null && resource !== cited) return null;
  const commentId = cited ?? resource;
  return { group: String(groupId), post: String(postId), ...(commentId === null ? {} : { comment: String(commentId) }) };
}
