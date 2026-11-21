import assert from 'node:assert/strict';
import { test } from 'node:test';
import { postNotificationTarget } from '../app/utils/post-notification-target.ts';

test('a reply points to the new comment and can fall back to its resource ID', () => {
  const notice = { resourceType: 'comment', resourceId: 7001 };
  for (const metadata of [
    { target_post_id: 42, comment_id: '7001', parent_comment_id: 7000 },
    { target_post_id: '01', post_id: 42, parent_comment_id: 7000 },
  ]) {
    assert.deepEqual(postNotificationTarget(notice, metadata), { postId: 42, commentId: 7001 });
  }
});

test('conflicting comment IDs, parent IDs and invalid IDs cannot cite a different comment', () => {
  assert.deepEqual(
    postNotificationTarget({ resourceType: 'comment', resourceId: 7001 }, { post_id: 42, comment_id: 7002 }),
    { postId: 42, commentId: null }
  );
  assert.deepEqual(
    postNotificationTarget({ resourceType: 'post', resourceId: 42 }, { post_id: 42.5, parent_comment_id: 7000 }),
    { postId: 42, commentId: null }
  );
});
