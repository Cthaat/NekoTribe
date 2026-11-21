export function notificationTargetId(value: unknown): number | null {
  const id = typeof value === 'string' && /^[1-9][0-9]{0,15}$/.test(value) &&
    value.trim() === value ? Number(value) : value;
  return typeof id === 'number' && Number.isSafeInteger(id) && id > 0 ? id : null;
}

export function postNotificationTarget(
  notice: { resourceType: string | null; resourceId: number | null },
  metadata: Record<string, unknown>
): { postId: number | null; commentId: number | null } {
  const postId = notificationTargetId(metadata.target_post_id) ?? notificationTargetId(metadata.post_id) ??
    notificationTargetId(metadata.source_post_id) ??
    (notice.resourceType === 'post' ? notificationTargetId(notice.resourceId) : null);
  const cited = notificationTargetId(metadata.comment_id);
  const resource = notice.resourceType === 'comment' ? notificationTargetId(notice.resourceId) : null;
  const commentId = cited !== null && resource !== null && cited !== resource
    ? null
    : cited ?? resource;
  return { postId, commentId };
}
