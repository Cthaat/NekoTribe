<script setup lang="ts">
import { onMounted, ref, watch } from 'vue';
import { toast } from 'vue-sonner';
import GroupList from '@/components/GroupList.vue';
import GroupDetailModal from '@/components/GroupDetailModal.vue';
import CreateGroupModal from '@/components/CreateGroupModal.vue';
import type {
  CreateGroupData,
  Group,
  GroupFiltersData
} from '@/types/groups';
const { t } = useAppLocale();

const filters = ref<GroupFiltersData>({
  search: '',
  privacy: 'all',
  category: 'all',
  sortBy: 'newest'
});

const groupList = useGroupList({
  mode: 'mine',
  filters
});
const groupDetail = useGroupDetail();

const groups = groupList.groups;
const loading = groupList.loading;
const detailModalOpen = groupDetail.open;
const createModalOpen = ref(false);
const selectedGroup = groupDetail.selectedGroup;
const members = groupDetail.members;
const posts = groupDetail.posts;

function syncSelectedGroup(groupId: number): void {
  if (selectedGroup.value?.id !== groupId) return;
  const updated = groups.value.find(
    group => group.id === groupId
  );
  if (updated) selectedGroup.value = updated;
}

onMounted(() => {
  void groupList.refresh();
});

watch(detailModalOpen, isOpen => {
  if (!isOpen) groupDetail.close();
});

async function handleLeave(id: number): Promise<void> {
  try {
    await groupList.leave(id);
    syncSelectedGroup(id);
    toast.success(t('groups.feedback.left'));
  } catch (error) {
    toast.error(t('groups.feedback.leaveFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

async function handleViewDetail(group: Group): Promise<void> {
  await groupDetail.openGroup(group);
}

function handleSettings(_id: number): void {
  toast.info(t('groups.feedback.settingsWip'));
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
</script>

<template>
  <div class="space-y-6">
    <!-- 群组列表 -->
    <GroupList
      :groups="groups"
      :loading="loading"
      :show-create-button="true"
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
      :members="members"
      :posts="posts"
      @leave="handleLeave"
      @settings="handleSettings"
      @invite="handleInvite"
    />

    <!-- 创建群组弹窗 -->
    <CreateGroupModal
      v-model:open="createModalOpen"
      @create="handleCreateSubmit"
    />
  </div>
</template>
