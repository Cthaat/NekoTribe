export function normalizeGroupInviteCode(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const code = raw.trim();
  return /^[a-zA-Z0-9]{1,32}$/.test(code) ? code.toUpperCase() : null;
}

// Empty search permits a link. A populated search requires a selected account.
export function groupInviteeId(query: string, chosenId: number | undefined): number | null | undefined {
  if (!query.trim()) return null;
  return chosenId !== undefined && Number.isSafeInteger(chosenId) && chosenId > 0
    ? chosenId
    : undefined;
}

export function matchesGroupInviteResponse(
  receipt: { invite_id: number; group_id: number; status: string } | null,
  inviteId: number,
  groupId: number,
  accepted: boolean
): boolean {
  return receipt?.invite_id === inviteId && receipt.group_id === groupId &&
    receipt.status === (accepted ? 'accepted' : 'rejected');
}
