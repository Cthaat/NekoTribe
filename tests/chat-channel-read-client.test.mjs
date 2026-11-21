import assert from 'node:assert/strict';
import { test } from 'node:test';
import { confirmedChatUnread, displayedChatCursor } from '../app/utils/chat-channel-read.ts';

test('read cursor is restricted to safely identified displayed messages', () => {
  assert.equal(displayedChatCursor([]), 0);
  assert.equal(displayedChatCursor([{ id: 7 }, { id: 10 }, { id: 5 }, { id: -1 }, { id: Number.MAX_SAFE_INTEGER + 1 }]), 10);
});

test('unread badge only changes after a matching monotonic acknowledgement', () => {
  const receipt = { channel_id: 7, last_read_message_id: 13, unread_count: 0 };
  assert.equal(confirmedChatUnread(7, 12, receipt), 0);
  assert.equal(confirmedChatUnread(7, 12, { ...receipt, unread_count: 2 }), 2);
  assert.equal(confirmedChatUnread(7, 12, { ...receipt, channel_id: 8 }), null);
  assert.equal(confirmedChatUnread(7, 12, { ...receipt, last_read_message_id: 11 }), null);
  assert.equal(confirmedChatUnread(7, 12, { ...receipt, last_read_message_id: null }), null);
  assert.equal(confirmedChatUnread(7, 12, { ...receipt, unread_count: -1 }), null);
});
