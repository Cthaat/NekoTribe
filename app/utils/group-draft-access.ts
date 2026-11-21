import type { Group } from '@/types/groups';

export function canUseGroupDrafts(group: Group | null | undefined): boolean {
  return group?.isActive === true && group.privacy === 'public' &&
    group.membershipStatus === 'active' &&
    (group.membershipRole === 'owner' || group.membershipRole === 'admin');
}
