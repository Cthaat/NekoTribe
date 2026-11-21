import {
  buildGroupStats,
  countJoinedGroups,
  createGroup,
  joinGroup,
  leaveGroup,
  listDiscoverGroups,
  listJoinedGroups,
  listPopularGroups
} from '@/services/groups';
import { authQueueFor } from '@/services/auth-request-queue';
import type { MaybeRef, Ref, ShallowRef } from 'vue';
import { onScopeDispose, toValue } from 'vue';
import type {
  CreateGroupData,
  Group,
  GroupFiltersData,
  GroupStatsData
} from '@/types/groups';

type GroupListMode = 'discover' | 'mine' | 'popular';

interface UseGroupListOptions {
  mode: MaybeRef<GroupListMode>;
  filters: Ref<GroupFiltersData>;
  pageSize?: number;
}

interface UseGroupListReturn {
  page: Ref<number>;
  pageSize: Ref<number>;
  groups: ShallowRef<Group[]>;
  loading: Ref<boolean>;
  error: Ref<string | null>;
  total: Ref<number>;
  hasNext: Ref<boolean>;
  stats: Ref<GroupStatsData>;
  refresh: () => Promise<void>;
  loadMore: () => Promise<void>;
  create: (data: CreateGroupData) => Promise<Group>;
  join: (groupId: number) => Promise<string>;
  leave: (groupId: number) => Promise<void>;
  patchGroup: (
    groupId: number,
    updater: (group: Group) => Group
  ) => void;
}

function defaultStats(): GroupStatsData {
  return {
    totalGroups: 0,
    myGroups: 0,
    pendingInvites: 0,
    todayPosts: 0,
    activeMembers: 0,
    newMembers: 0
  };
}

export function useGroupList(
  options: UseGroupListOptions
): UseGroupListReturn {
  const app = useNuxtApp();
  const auth = authQueueFor(app);
  const page = ref(1);
  const pageSize = ref(options.pageSize ?? 12);
  const groups = shallowRef<Group[]>([]);
  const loading = ref(false);
  const error = ref<string | null>(null);
  const total = ref(0);
  const hasNext = ref(false);
  const stats = ref<GroupStatsData>(defaultStats());
  let request = 0;
  let disposed = false;
  const currentSession = (revision: number) =>
    !disposed && auth.revision === revision && !auth.isIdentityChanging;
  const unsubscribe = auth.subscribe(() => {
    request++;
    page.value = 1;
    groups.value = [];
    total.value = 0;
    loading.value = false;
    error.value = null;
    hasNext.value = false;
    stats.value = defaultStats();
  });
  onScopeDispose(() => {
    disposed = true;
    request++;
    unsubscribe();
  });

  async function loadPage(
    nextPage: number,
    append: boolean
  ): Promise<void> {
    const revision = auth.revision;
    if (!currentSession(revision)) return;
    const current = ++request;
    loading.value = true;
    error.value = null;

    try {
      const mode = toValue(options.mode);
      const result =
        mode === 'popular'
          ? await listPopularGroups()
          : mode === 'mine'
          ? await listJoinedGroups(
              options.filters.value,
              nextPage,
              pageSize.value
            )
          : await listDiscoverGroups(
              options.filters.value,
              nextPage,
              pageSize.value
            );

      if (request !== current) return;
      page.value = nextPage;
      groups.value = append
        ? [...groups.value, ...result.groups]
        : result.groups;
      total.value = result.total;
      hasNext.value = result.hasNext;

      if (mode === 'popular') return;

      const joinedCount =
        mode === 'mine'
          ? result.total
          : await app.runWithContext(() => countJoinedGroups());
      if (request !== current) return;
      stats.value = buildGroupStats(
        groups.value,
        result.total,
        joinedCount
      );
    } catch (caught) {
      if (request !== current) return;
      error.value =
        caught instanceof Error
          ? caught.message
          : '加载群组失败';
      if (!append) {
        groups.value = [];
        total.value = 0;
        hasNext.value = false;
        stats.value = defaultStats();
      }
    } finally {
      if (request === current) loading.value = false;
    }
  }

  async function refresh(): Promise<void> {
    await loadPage(1, false);
  }

  async function loadMore(): Promise<void> {
    if (loading.value || !hasNext.value) return;
    await loadPage(page.value + 1, true);
  }

  function patchGroup(
    groupId: number,
    updater: (group: Group) => Group
  ): void {
    groups.value = groups.value.map(group =>
      group.id === groupId ? updater(group) : group
    );
  }

  async function create(data: CreateGroupData): Promise<Group> {
    const revision = auth.revision;
    const group = await createGroup(data);
    if (!currentSession(revision)) return group;
    if (toValue(options.mode) === 'popular') {
      await app.runWithContext(refresh);
      return group;
    }
    groups.value = [group, ...groups.value];
    total.value += 1;
    stats.value = {
      ...stats.value,
      totalGroups: stats.value.totalGroups + 1,
      myGroups: stats.value.myGroups + 1
    };
    return group;
  }

  async function join(groupId: number): Promise<string> {
    const revision = auth.revision;
    if (!currentSession(revision)) throw Error('GROUP_SESSION_CHANGED');
    const status = await joinGroup(groupId);
    if (currentSession(revision)) await app.runWithContext(refresh);
    return status;
  }

  async function leave(groupId: number): Promise<void> {
    const revision = auth.revision;
    if (!currentSession(revision)) throw Error('GROUP_SESSION_CHANGED');
    await leaveGroup(groupId);
    if (currentSession(revision)) await app.runWithContext(refresh);
  }

  return {
    page,
    pageSize,
    groups,
    loading,
    error,
    total,
    hasNext,
    stats,
    refresh,
    loadMore,
    create,
    join,
    leave,
    patchGroup
  };
}
