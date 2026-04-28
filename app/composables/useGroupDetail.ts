import {
  createGroupInvite,
  loadGroupDetail
} from '@/services/groups';
import type { Ref, ShallowRef } from 'vue';
import type {
  Group,
  GroupMember,
  GroupPost
} from '@/types/groups';

interface UseGroupDetailReturn {
  open: Ref<boolean>;
  selectedGroup: Ref<Group | null>;
  members: ShallowRef<GroupMember[]>;
  posts: ShallowRef<GroupPost[]>;
  loading: Ref<boolean>;
  error: Ref<string | null>;
  openGroup: (group: Group) => Promise<void>;
  refresh: () => Promise<void>;
  createInvite: (
    groupId: number
  ) => Promise<string | null>;
  close: () => void;
}

export function useGroupDetail(): UseGroupDetailReturn {
  const open = ref(false);
  const selectedGroup = ref<Group | null>(null);
  const members = shallowRef<GroupMember[]>([]);
  const posts = shallowRef<GroupPost[]>([]);
  const loading = ref(false);
  const error = ref<string | null>(null);

  async function openGroup(group: Group): Promise<void> {
    selectedGroup.value = group;
    open.value = true;
    await refresh();
  }

  async function refresh(): Promise<void> {
    if (!selectedGroup.value) return;
    loading.value = true;
    error.value = null;

    try {
      const result = await loadGroupDetail(
        selectedGroup.value.id
      );
      members.value = result.members;
      posts.value = result.posts;
    } catch (caught) {
      error.value =
        caught instanceof Error
          ? caught.message
          : '加载群组详情失败';
      members.value = [];
      posts.value = [];
    } finally {
      loading.value = false;
    }
  }

  async function createInvite(
    groupId: number
  ): Promise<string | null> {
    const inviteUrl = await createGroupInvite(groupId);
    if (
      inviteUrl &&
      typeof navigator !== 'undefined' &&
      navigator.clipboard
    ) {
      await navigator.clipboard.writeText(inviteUrl);
    }
    return inviteUrl;
  }

  function close(): void {
    open.value = false;
    selectedGroup.value = null;
    members.value = [];
    posts.value = [];
    error.value = null;
  }

  return {
    open,
    selectedGroup,
    members,
    posts,
    loading,
    error,
    openGroup,
    refresh,
    createInvite,
    close
  };
}
