<script setup lang="ts">
import { ref, computed } from 'vue';
import { toast } from 'vue-sonner';
import { Inbox, Plus } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import GroupList from '@/components/GroupList.vue';
import GroupDetailModal from '@/components/GroupDetailModal.vue';
import CreateGroupModal from '@/components/CreateGroupModal.vue';
import type { Group } from '@/components/GroupCard.vue';
import type { GroupMember } from '@/components/GroupMemberCard.vue';
import type { GroupPost } from '@/components/GroupPostCard.vue';

definePageMeta({
  layout: false
});

// 模拟我的群组数据（已加入的群组）
const myGroups = ref<Group[]>([
  {
    id: 1,
    name: 'Vue.js 开发者社区',
    description:
      '一个专注于 Vue.js 技术分享和讨论的社区，欢迎所有 Vue 爱好者加入！',
    avatar:
      'https://api.dicebear.com/7.x/identicon/svg?seed=vue',
    coverImage: 'https://picsum.photos/800/200?random=1',
    privacy: 'public',
    memberCount: 2580,
    postCount: 456,
    createdAt: '2024-01-15T08:00:00Z',
    owner: {
      id: 1,
      username: 'vuefan',
      nickname: 'Vue爱好者',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=vuefan'
    },
    isMember: true,
    isOwner: false,
    isAdmin: false,
    category: '科技',
    tags: ['Vue', '前端', 'JavaScript']
  },
  {
    id: 3,
    name: '摄影爱好者俱乐部',
    description:
      '分享摄影作品、交流拍摄技巧，不定期组织线下采风活动。',
    avatar:
      'https://api.dicebear.com/7.x/identicon/svg?seed=photo',
    coverImage: 'https://picsum.photos/800/200?random=3',
    privacy: 'private',
    memberCount: 567,
    postCount: 1234,
    createdAt: '2024-03-10T14:00:00Z',
    owner: {
      id: 999,
      username: 'currentuser',
      nickname: '当前用户',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=currentuser'
    },
    isMember: true,
    isOwner: true,
    isAdmin: true,
    category: '艺术',
    tags: ['摄影', '风光', '人像']
  },
  {
    id: 5,
    name: '健身打卡小组',
    description: '每日健身打卡，互相监督，一起变得更强！',
    avatar:
      'https://api.dicebear.com/7.x/identicon/svg?seed=fitness',
    coverImage: 'https://picsum.photos/800/200?random=5',
    privacy: 'public',
    memberCount: 2100,
    postCount: 3456,
    createdAt: '2024-05-01T06:00:00Z',
    owner: {
      id: 5,
      username: 'fitnessguru',
      nickname: '健身达人',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=fitnessguru'
    },
    isMember: true,
    isOwner: false,
    isAdmin: true,
    category: '生活',
    tags: ['健身', '运动', '打卡']
  }
]);

// 模拟成员数据
const mockMembers: GroupMember[] = [
  {
    id: 1,
    userId: 999,
    username: 'currentuser',
    nickname: '当前用户',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=currentuser',
    role: 'owner',
    joinedAt: '2024-03-10T14:00:00Z'
  },
  {
    id: 2,
    userId: 2,
    username: 'member1',
    nickname: '成员一',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=member1',
    role: 'admin',
    joinedAt: '2024-03-15T10:00:00Z'
  },
  {
    id: 3,
    userId: 3,
    username: 'member2',
    nickname: '成员二',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=member2',
    role: 'member',
    joinedAt: '2024-04-01T14:00:00Z'
  }
];

// 模拟帖子数据
const mockPosts: GroupPost[] = [
  {
    id: 1,
    content:
      '今天的摄影作品分享！在日落时分拍摄的城市天际线。',
    author: {
      id: 999,
      username: 'currentuser',
      nickname: '当前用户',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=currentuser',
      role: 'owner'
    },
    media: [
      {
        type: 'image',
        url: 'https://picsum.photos/800/600?random=20'
      }
    ],
    isPinned: true,
    likeCount: 89,
    commentCount: 23,
    isLiked: false,
    createdAt: '2024-12-15T18:00:00Z'
  }
];

// 状态
const loading = ref(false);
const detailModalOpen = ref(false);
const createModalOpen = ref(false);
const selectedGroup = ref<Group | null>(null);

// 事件处理
const handleLeave = (id: number) => {
  const index = myGroups.value.findIndex(g => g.id === id);
  if (index !== -1) {
    myGroups.value.splice(index, 1);
    toast.success('已离开群组');
  }
};

const handleViewDetail = (group: Group) => {
  selectedGroup.value = group;
  detailModalOpen.value = true;
};

const handleSettings = (id: number) => {
  toast.info('群组设置功能开发中...');
};

const handleRefresh = () => {
  loading.value = true;
  setTimeout(() => {
    loading.value = false;
    toast.success('列表已刷新');
  }, 1000);
};

const handleLoadMore = () => {
  toast.info('没有更多群组了');
};

const handleCreate = () => {
  createModalOpen.value = true;
};

const handleCreateSubmit = (data: any) => {
  const newGroup: Group = {
    id: myGroups.value.length + 100,
    name: data.name,
    description: data.description,
    avatar: `https://api.dicebear.com/7.x/identicon/svg?seed=${data.name}`,
    privacy: data.privacy,
    memberCount: 1,
    postCount: 0,
    createdAt: new Date().toISOString(),
    owner: {
      id: 999,
      username: 'currentuser',
      nickname: '当前用户',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=currentuser'
    },
    isMember: true,
    isOwner: true,
    isAdmin: true,
    category: data.category
  };
  myGroups.value.unshift(newGroup);
};

const handleInvite = (id: number) => {
  toast.success('邀请链接已复制到剪贴板');
};
</script>

<template>
  <div class="space-y-6">
    <!-- 群组列表 -->
    <GroupList
      :groups="myGroups"
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
      :members="mockMembers"
      :posts="mockPosts"
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
