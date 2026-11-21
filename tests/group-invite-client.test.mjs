import assert from 'node:assert/strict';
import test from 'node:test';
import { groupInviteeId, matchesGroupInviteResponse, normalizeGroupInviteCode } from '../app/utils/group-invite.ts';

test('invite continuation normalizes only a single ASCII code', () => {
  assert.equal(normalizeGroupInviteCode(' aBc123 '), 'ABC123');
  assert.equal(normalizeGroupInviteCode('0123456789ABCDEF'.repeat(2)), '0123456789ABCDEF'.repeat(2));
  for (const invalid of [null, ['ABC'], '', '雪', 'a/b', 'a%2Fb', 'A'.repeat(33), 'https://example.test']) {
    assert.equal(normalizeGroupInviteCode(invalid), null);
  }
});

test('an unresolved recipient search cannot submit a link', () => {
  assert.equal(groupInviteeId(' ', undefined), null);
  assert.equal(groupInviteeId('recip', undefined), undefined);
  assert.equal(groupInviteeId('recip', 0), undefined);
  assert.equal(groupInviteeId('recip', Number.MAX_SAFE_INTEGER + 1), undefined);
  assert.equal(groupInviteeId('recip', 77), 77);
  assert.equal(groupInviteeId('', 77), null);
});

test('invite response must confirm the same invite, group and action', () => {
  const receipt = { invite_id: 10, group_id: 20, status: 'accepted' };
  assert.equal(matchesGroupInviteResponse(receipt, 10, 20, true), true);
  assert.equal(matchesGroupInviteResponse(receipt, 11, 20, true), false);
  assert.equal(matchesGroupInviteResponse(receipt, 10, 21, true), false);
  assert.equal(matchesGroupInviteResponse(receipt, 10, 20, false), false);
  assert.equal(matchesGroupInviteResponse(null, 10, 20, true), false);
});
