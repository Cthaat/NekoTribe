import assert from 'node:assert/strict';
import { test } from 'node:test';
import { confirmedChannelMute } from '../app/utils/chat-channel-mute.ts';

test('mute receipts must identify the affected channel and contain a boolean', () => {
  assert.equal(confirmedChannelMute(7, { channel_id: 7, is_muted: true }), true);
  assert.equal(confirmedChannelMute(7, { channel_id: 7, is_muted: false }), false);
  for (const value of [null, {}, { channel_id: 8, is_muted: true }, { channel_id: '7', is_muted: true },
    { channel_id: 7, is_muted: 'false' }, { channel_id: 7, is_muted: null }]) {
    assert.throws(() => confirmedChannelMute(7, value), /INVALID_CHAT_MUTE_RECEIPT/);
  }
});
