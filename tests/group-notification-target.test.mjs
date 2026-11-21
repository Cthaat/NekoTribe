import assert from 'node:assert/strict';
import test from 'node:test';
import { groupNotificationQuery } from '../app/utils/group-notification-target.ts';

test('group comment notices target the new reply, including legacy resource IDs', () => {
  const notice = { type: 'group_comment', resourceType: 'group_comment', resourceId: 17 };
  const metadata = { group_id: '42', post_id: 9, parent_comment_id: 12 };
  assert.deepEqual(groupNotificationQuery(notice, metadata), { group: '42', post: '9', comment: '17' });
  assert.equal(groupNotificationQuery(notice, { ...metadata, comment_id: 18 }), null);
  assert.equal(groupNotificationQuery(notice, { ...metadata, post_id: 9.9 }), null);
  assert.equal(groupNotificationQuery(notice, { post_id: 9 }), null);
});

test('group post notices can use their resource as the post ID, but never as a comment', () => {
  const notice = { type: 'group_post', resourceType: 'group_post', resourceId: 9 };
  assert.deepEqual(groupNotificationQuery(notice, { group_id: 42, comment_id: 12 }), { group: '42', post: '9' });
  assert.equal(groupNotificationQuery(notice, { group_id: '0042' }), null);
});
