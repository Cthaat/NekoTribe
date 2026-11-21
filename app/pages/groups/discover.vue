<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { toast } from 'vue-sonner';
import GroupStats from '@/components/GroupStats.vue';
import GroupFilters from '@/components/GroupFilters.vue';
import GroupList from '@/components/GroupList.vue';
import GroupDetailModal from '@/components/GroupDetailModal.vue';
import CreateGroupModal from '@/components/CreateGroupModal.vue';
import GroupManageModal from '@/components/GroupManageModal.vue';
import { Button } from '@/components/ui/button';
import { authQueueFor } from '@/services/auth-request-queue';
import type {
  CreateGroupData,
  Group,
  GroupFiltersData
} from '@/types/groups';
const { t } = useAppLocale();
const auth = authQueueFor(useNuxtApp());
const route = useRoute();
const router = useRouter();
const linkedSlug = computed(() =>
  typeof route.query.slug === 'string' && route.query.slug.length > 0
    ? route.query.slug : null
);
const mode = ref<'discover' | 'popular'>('discover');

const filters = ref<GroupFiltersData>({
  search: '',
  privacy: 'all',
  category: 'all',
  sortBy: 'popular'
});

const groupList = useGroupList({
  mode,
  filters
});
const groupDetail = useGroupDetail();

const createModalOpen = ref(false);
const manageModalOpen = ref(false);
const manageGroup = ref<Group | null>(null);
const groups = groupList.groups;
const loading = groupList.loading;
const statsData = groupList.stats;
const detailModalOpen = groupDetail.open;
const selectedGroup = groupDetail.selectedGroup;
const members = groupDetail.members;
const posts = groupDetail.posts;

onMounted(() => {
  void groupList.refresh();
  if (linkedSlug.value) void groupDetail.openGroupBySlug(linkedSlug.value);
});

watch(linkedSlug, (slug, previous) => {
  if (slug) void groupDetail.openGroupBySlug(slug);
  else if (previous) groupDetail.close();
});

watch(
  [mode, filters],
  () => {
    void groupList.refresh();
  },
  { deep: true, flush: 'sync' }
);

watch(detailModalOpen, isOpen => {
  if (!isOpen) groupDetail.close();
});

async function handleJoin(id: number): Promise<void> {
  const revision = auth.revision;
  try {
    const status = await groupList.join(id);
    if (revision !== auth.revision) return;
    if (selectedGroup.value?.id === id) void groupDetail.refresh();
    toast.success(
      status === 'active'
        ? t('groups.feedback.joined')
        : t('groups.feedback.joinRequested')
    );
  } catch (error) {
    if (revision !== auth.revision) return;
    toast.error(t('groups.feedback.joinFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

async function handleLeave(id: number): Promise<void> {
  const revision = auth.revision;
  const pending = (selectedGroup.value?.id === id
    ? selectedGroup.value
    : groups.value.find(group => group.id === id))?.membershipStatus === 'pending';
  try {
    await groupList.leave(id);
    if (revision !== auth.revision) return;
    if (selectedGroup.value?.id === id) void groupDetail.refresh();
    toast.success(t(pending ? 'groups.feedback.requestCanceled' : 'groups.feedback.left'));
  } catch (error) {
    if (revision !== auth.revision) return;
    toast.error(t('groups.feedback.leaveFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

async function handleViewDetail(group: Group): Promise<void> {
  if (group.slug && linkedSlug.value !== group.slug) {
    await router.replace({
      path: route.path,
      query: { ...route.query, slug: group.slug },
      hash: route.hash
    });
    return;
  }
  await groupDetail.openGroup(group);
}

function handleSettings(id: number): void {
  const group =
    groups.value.find(item => item.id === id) ??
    (selectedGroup.value?.id === id ? selectedGroup.value : null);
  if (!group) return;
  manageGroup.value = group;
  manageModalOpen.value = true;
}

async function handleRefresh(): Promise<void> {
  await groupList.refresh();
  toast.success(
    groupList.error.value
      ? t('groups.feedback.refreshFailed')
      : t('groups.feedback.refreshed')
  );
}

async function handleLoadMore(): Promise<void> {
  if (!groupList.hasNext.value) {
    toast.info(t('groups.feedback.noMore'));
    return;
  }
  await groupList.loadMore();
}

function handleCreate(): void {
  createModalOpen.value = true;
}

async function handleCreateSubmit(
  data: CreateGroupData
): Promise<void> {
  try {
    await groupList.create(data);
    toast.success(t('groups.feedback.created'));
  } catch (error) {
    toast.error(t('groups.feedback.createFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

function handleResetFilters(): void {
  toast.info(t('groups.feedback.filtersReset'));
}

async function handleInvite(id: number): Promise<void> {
  try {
    const inviteUrl = await groupDetail.createInvite(id);
    toast.success(
      inviteUrl
        ? t('groups.feedback.inviteCopied')
        : t('groups.feedback.inviteCreated')
    );
  } catch (error) {
    toast.error(t('groups.feedback.inviteFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

function handleGroupUpdated(group: Group): void {
  groupList.patchGroup(group.id, () => group);
  if (mode.value === 'popular') void groupList.refresh();
  if (selectedGroup.value?.id === group.id) {
    selectedGroup.value = group;
  }
  if (manageGroup.value?.id === group.id) {
    manageGroup.value = group;
  }
}

async function handleMembersUpdated(groupId: number): Promise<void> {
  if (selectedGroup.value?.id !== groupId) return;
  await groupDetail.refresh();
}

async function handleGroupDeleted(groupId: number): Promise<void> {
  manageModalOpen.value = false;
  manageGroup.value = null;
  if (selectedGroup.value?.id === groupId) {
    detailModalOpen.value = false;
  }
  await groupList.refresh();
}
</script>

<template>
  <div class="space-y-6">
    <div class="flex flex-wrap gap-2">
      <Button
        :variant="mode === 'discover' ? 'default' : 'outline'"
        :aria-pressed="mode === 'discover'"
        @click="mode = 'discover'"
      >{{ t('groups.tabs.discover') }}</Button>
      <Button
        :variant="mode === 'popular' ? 'default' : 'outline'"
        :aria-pressed="mode === 'popular'"
        @click="mode = 'popular'"
      >{{ t('groups.tabs.popular') }}</Button>
    </div>
    <!-- 统计面板 -->
    <GroupStats v-if="mode === 'discover'" :stats="statsData" />

    <!-- 过滤器 -->
    <GroupFilters
      v-if="mode === 'discover'"
      v-model="filters"
      @reset="handleResetFilters"
    />

    <!-- 群组列表 -->
    <GroupList
      :groups="groups"
      :loading="loading"
      :has-next="mode === 'discover' && groupList.hasNext.value"
      :show-create-button="true"
      @join="handleJoin"
      @leave="handleLeave"
      @view-detail="handleViewDetail"
      @settings="handleSettings"
      @refresh="handleRefresh"
      @load-more="handleLoadMore"
      @create="handleCreate"
    />

    <!-- 群组详情弹窗 -->
    <GroupDetailModal
      v-model:open="detailModalOpen"
      :group="selectedGroup"
      :loading="groupDetail.loading.value"
      :error="groupDetail.error.value"
      @retry="groupDetail.refresh"
      :members="members"
      :posts="posts"
      @join="handleJoin"
      @leave="handleLeave"
      @settings="handleSettings"
      @invite="handleInvite"
      @updated="handleGroupUpdated"
      @members-updated="handleMembersUpdated"
    />

    <!-- 创建群组弹窗 -->
    <CreateGroupModal
      v-model:open="createModalOpen"
      @create="handleCreateSubmit"
    />

    <GroupManageModal
      v-model:open="manageModalOpen"
      :group="manageGroup"
      @updated="handleGroupUpdated"
      @deleted="handleGroupDeleted"
    />
  </div>
</template>
