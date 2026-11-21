import {
  createGroupInvite,
  getGroup,
  getGroupBySlug,
  loadGroupDetail
} from '@/services/groups';
import { authQueueFor } from '@/services/auth-request-queue';
import { onScopeDispose } from 'vue';
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
  openGroupBySlug: (slug: string) => Promise<void>;
  refresh: () => Promise<void>;
  createInvite: (
    groupId: number
  ) => Promise<string | null>;
  close: () => void;
}

export function useGroupDetail(): UseGroupDetailReturn {
  const app = useNuxtApp();
  const auth = authQueueFor(app);
  const open = ref(false);
  const selectedGroup = ref<Group | null>(null);
  const members = shallowRef<GroupMember[]>([]);
  const posts = shallowRef<GroupPost[]>([]);
  const loading = ref(false);
  const error = ref<string | null>(null);
  let request = 0;
  let lookup: number | string | null = null;
  const unsubscribe = auth.subscribe(close);
  onScopeDispose(() => {
    unsubscribe();
    close();
  });

  async function openGroup(group: Group): Promise<void> {
    if (auth.isIdentityChanging) return;
    lookup = group.id;
    selectedGroup.value = group;
    open.value = true;
    await refresh();
  }

  async function openGroupBySlug(slug: string): Promise<void> {
    if (!slug || auth.isIdentityChanging) return;
    lookup = slug;
    selectedGroup.value = null;
    open.value = true;
    await refresh();
  }

  async function refresh(): Promise<void> {
    const target = lookup;
    if (!open.value || target === null || auth.isIdentityChanging) return;
    const current = ++request;
    const revision = auth.revision;
    const isCurrent = () => current === request && revision === auth.revision &&
      open.value && lookup === target;
    loading.value = true;
    error.value = null;
    members.value = [];
    posts.value = [];

    try {
      const group = await app.runWithContext(() =>
        typeof target === 'number' ? getGroup(target) : getGroupBySlug(target)
      );
      if (!isCurrent()) return;
      selectedGroup.value = group;
      const result = await app.runWithContext(() => loadGroupDetail(group));
      if (!isCurrent()) return;
      members.value = result.members;
      posts.value = result.posts;
    } catch (caught) {
      if (!isCurrent()) return;
      selectedGroup.value = null;
      error.value =
        caught instanceof Error
          ? caught.message
          : '加载群组详情失败';
      members.value = [];
      posts.value = [];
    } finally {
      if (isCurrent()) loading.value = false;
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
    request++;
    lookup = null;
    open.value = false;
    selectedGroup.value = null;
    members.value = [];
    posts.value = [];
    error.value = null;
    loading.value = false;
  }

  return {
    open,
    selectedGroup,
    members,
    posts,
    loading,
    error,
    openGroup,
    openGroupBySlug,
    refresh,
    createInvite,
    close
  };
}
