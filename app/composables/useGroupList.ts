import {
  buildGroupStats,
  countJoinedGroups,
  createGroup,
  joinGroup,
  leaveGroup,
  listDiscoverGroups,
  listJoinedGroups
} from '@/services/groups';
import type { Ref, ShallowRef } from 'vue';
import type {
  CreateGroupData,
  Group,
  GroupFiltersData,
  GroupStatsData
} from '@/types/groups';

type GroupListMode = 'discover' | 'mine';

interface UseGroupListOptions {
  mode: GroupListMode;
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
  const page = ref(1);
  const pageSize = ref(options.pageSize ?? 12);
  const groups = shallowRef<Group[]>([]);
  const loading = ref(false);
  const error = ref<string | null>(null);
  const total = ref(0);
  const hasNext = ref(false);
  const stats = ref<GroupStatsData>(defaultStats());

  async function loadPage(
    nextPage: number,
    append: boolean
  ): Promise<void> {
    loading.value = true;
    error.value = null;

    try {
      const result =
        options.mode === 'mine'
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

      page.value = nextPage;
      groups.value = append
        ? [...groups.value, ...result.groups]
        : result.groups;
      total.value = result.total;
      hasNext.value = result.hasNext;

      const joinedCount =
        options.mode === 'mine'
          ? result.total
          : await countJoinedGroups();
      stats.value = buildGroupStats(
        groups.value,
        result.total,
        joinedCount
      );
    } catch (caught) {
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
      loading.value = false;
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
    const group = await createGroup(data);
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
    const status = await joinGroup(groupId);
    patchGroup(groupId, group => ({
      ...group,
      isMember: true,
      membershipStatus: status,
      memberCount:
        status === 'active'
          ? group.memberCount + 1
          : group.memberCount
    }));
    return status;
  }

  async function leave(groupId: number): Promise<void> {
    await leaveGroup(groupId);
    if (options.mode === 'mine') {
      groups.value = groups.value.filter(
        group => group.id !== groupId
      );
      total.value = Math.max(total.value - 1, 0);
    } else {
      patchGroup(groupId, group => ({
        ...group,
        isMember: false,
        membershipStatus: null,
        memberCount: Math.max(group.memberCount - 1, 0)
      }));
    }
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
