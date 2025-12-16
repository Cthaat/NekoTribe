<script setup lang="ts">
import { ref, computed } from 'vue';
import { toast } from 'vue-sonner';
import GroupStats from '@/components/GroupStats.vue';
import GroupFilters from '@/components/GroupFilters.vue';
import GroupList from '@/components/GroupList.vue';
import GroupDetailModal from '@/components/GroupDetailModal.vue';
import CreateGroupModal from '@/components/CreateGroupModal.vue';
import type { Group } from '@/components/GroupCard.vue';
import type { GroupStatsData } from '@/components/GroupStats.vue';
import type { GroupFiltersData } from '@/components/GroupFilters.vue';
import type { GroupMember } from '@/components/GroupMemberCard.vue';
import type { GroupPost } from '@/components/GroupPostCard.vue';

// ==================== 测试数据 ====================

// 模拟统计数据
const statsData = ref<GroupStatsData>({
  totalGroups: 128,
  myGroups: 8,
  pendingInvites: 3,
  todayPosts: 56,
  activeMembers: 1024,
  newMembers: 42
});

// 模拟群组数据
const mockGroups: Group[] = [
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
    id: 2,
    name: '独立游戏开发者联盟',
    description:
      '聚集独立游戏开发者，分享开发经验、素材资源和最新作品，共同成长！',
    avatar:
      'https://api.dicebear.com/7.x/identicon/svg?seed=gamedev',
    coverImage: 'https://picsum.photos/800/200?random=2',
    privacy: 'public',
    memberCount: 1234,
    postCount: 789,
    createdAt: '2024-02-20T10:30:00Z',
    owner: {
      id: 2,
      username: 'gamemaker',
      nickname: '游戏制作人',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=gamemaker'
    },
    isMember: false,
    isOwner: false,
    isAdmin: false,
    category: '游戏',
    tags: ['游戏开发', 'Unity', 'Godot']
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
      id: 3,
      username: 'photographer',
      nickname: '光影猎人',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=photographer'
    },
    isMember: true,
    isOwner: true,
    isAdmin: true,
    category: '艺术',
    tags: ['摄影', '风光', '人像']
  },
  {
    id: 4,
    name: '音乐创作交流群',
    description:
      '无论是编曲、作词还是演奏，这里都是音乐人的家园。',
    avatar:
      'https://api.dicebear.com/7.x/identicon/svg?seed=music',
    coverImage: 'https://picsum.photos/800/200?random=4',
    privacy: 'public',
    memberCount: 890,
    postCount: 567,
    createdAt: '2024-04-05T09:00:00Z',
    owner: {
      id: 4,
      username: 'musician',
      nickname: '音乐创作者',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=musician'
    },
    isMember: false,
    isOwner: false,
    isAdmin: false,
    category: '音乐',
    tags: ['音乐', '编曲', '创作']
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
  },
  {
    id: 6,
    name: '私密读书会',
    description: '每月共读一本书，深度讨论，仅限邀请加入。',
    avatar:
      'https://api.dicebear.com/7.x/identicon/svg?seed=book',
    coverImage: 'https://picsum.photos/800/200?random=6',
    privacy: 'secret',
    memberCount: 50,
    postCount: 234,
    createdAt: '2024-06-15T20:00:00Z',
    owner: {
      id: 6,
      username: 'booklover',
      nickname: '书虫',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=booklover'
    },
    isMember: false,
    isOwner: false,
    isAdmin: false,
    category: '学习',
    tags: ['读书', '分享', '讨论']
  }
];

// 模拟成员数据
const mockMembers: GroupMember[] = [
  {
    id: 1,
    userId: 1,
    username: 'vuefan',
    nickname: 'Vue爱好者',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=vuefan',
    role: 'owner',
    joinedAt: '2024-01-15T08:00:00Z'
  },
  {
    id: 2,
    userId: 2,
    username: 'developer1',
    nickname: '前端工程师',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=developer1',
    role: 'admin',
    joinedAt: '2024-01-20T10:00:00Z'
  },
  {
    id: 3,
    userId: 3,
    username: 'coder123',
    nickname: '代码爱好者',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=coder123',
    role: 'member',
    joinedAt: '2024-02-01T14:00:00Z',
    isMuted: true
  },
  {
    id: 4,
    userId: 4,
    username: 'newbie',
    nickname: '新手小白',
    avatar:
      'https://api.dicebear.com/7.x/avataaars/svg?seed=newbie',
    role: 'member',
    joinedAt: '2024-03-15T09:00:00Z'
  }
];

// 模拟帖子数据
const mockPosts: GroupPost[] = [
  {
    id: 1,
    content:
      '欢迎大家加入我们的社区！这里是 Vue.js 开发者的家园，请遵守社区规则，友善交流。\n\n有任何问题可以在这里提问，我们会尽力帮助大家！',
    author: {
      id: 1,
      username: 'vuefan',
      nickname: 'Vue爱好者',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=vuefan',
      role: 'owner'
    },
    isPinned: true,
    likeCount: 128,
    commentCount: 45,
    isLiked: true,
    createdAt: '2024-01-15T08:30:00Z'
  },
  {
    id: 2,
    content:
      '刚刚用 Vue 3 + Vite 搭建了一个新项目，速度真的太快了！分享一下我的配置心得...',
    author: {
      id: 2,
      username: 'developer1',
      nickname: '前端工程师',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=developer1',
      role: 'admin'
    },
    media: [
      {
        type: 'image',
        url: 'https://picsum.photos/800/600?random=10'
      }
    ],
    isPinned: false,
    likeCount: 56,
    commentCount: 23,
    isLiked: false,
    createdAt: '2024-12-15T14:00:00Z'
  },
  {
    id: 3,
    content:
      '请问大家有什么好用的 Vue 组件库推荐吗？准备开始一个新项目。',
    author: {
      id: 4,
      username: 'newbie',
      nickname: '新手小白',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=newbie',
      role: 'member'
    },
    isPinned: false,
    likeCount: 12,
    commentCount: 34,
    isLiked: false,
    createdAt: '2024-12-16T09:00:00Z'
  }
];

// ==================== 状态管理 ====================

// 过滤器状态
const filters = ref<GroupFiltersData>({
  search: '',
  privacy: 'all',
  category: 'all',
  sortBy: 'popular'
});

// 群组列表
const groups = ref<Group[]>([...mockGroups]);

// 加载状态
const loading = ref(false);

// 弹窗状态
const detailModalOpen = ref(false);
const createModalOpen = ref(false);
const selectedGroup = ref<Group | null>(null);

// ==================== 过滤逻辑 ====================

const filteredGroups = computed(() => {
  let result = [...groups.value];

  // 搜索过滤
  if (filters.value.search) {
    const searchLower = filters.value.search.toLowerCase();
    result = result.filter(
      g =>
        g.name.toLowerCase().includes(searchLower) ||
        g.description.toLowerCase().includes(searchLower)
    );
  }

  // 隐私过滤
  if (filters.value.privacy !== 'all') {
    result = result.filter(
      g => g.privacy === filters.value.privacy
    );
  }

  // 分类过滤
  if (filters.value.category !== 'all') {
    const categoryMap: Record<string, string> = {
      tech: '科技',
      game: '游戏',
      music: '音乐',
      art: '艺术',
      life: '生活',
      study: '学习',
      work: '工作',
      other: '其他'
    };
    const category = categoryMap[filters.value.category];
    result = result.filter(g => g.category === category);
  }

  // 排序
  switch (filters.value.sortBy) {
    case 'popular':
      result.sort((a, b) => b.memberCount - a.memberCount);
      break;
    case 'newest':
      result.sort(
        (a, b) =>
          new Date(b.createdAt).getTime() -
          new Date(a.createdAt).getTime()
      );
      break;
    case 'active':
      result.sort((a, b) => b.postCount - a.postCount);
      break;
    case 'members':
      result.sort((a, b) => b.memberCount - a.memberCount);
      break;
  }

  return result;
});

// ==================== 事件处理 ====================

// 加入群组
const handleJoin = (id: number) => {
  const index = groups.value.findIndex(g => g.id === id);
  if (index !== -1) {
    groups.value[index].isMember = true;
    groups.value[index].memberCount++;
    statsData.value.myGroups++;
  }
};

// 离开群组
const handleLeave = (id: number) => {
  const index = groups.value.findIndex(g => g.id === id);
  if (index !== -1) {
    groups.value[index].isMember = false;
    groups.value[index].memberCount--;
    statsData.value.myGroups--;
  }
};

// 查看详情
const handleViewDetail = (group: Group) => {
  selectedGroup.value = group;
  detailModalOpen.value = true;
};

// 群组设置
const handleSettings = (id: number) => {
  toast.info('群组设置功能开发中...');
};

// 刷新列表
const handleRefresh = () => {
  loading.value = true;
  setTimeout(() => {
    groups.value = [...mockGroups];
    loading.value = false;
    toast.success('列表已刷新');
  }, 1000);
};

// 加载更多
const handleLoadMore = () => {
  toast.info('没有更多群组了');
};

// 创建群组
const handleCreate = () => {
  createModalOpen.value = true;
};

// 创建群组提交
const handleCreateSubmit = (data: any) => {
  const newGroup: Group = {
    id: groups.value.length + 1,
    name: data.name,
    description: data.description,
    avatar:
      data.avatar ||
      `https://api.dicebear.com/7.x/identicon/svg?seed=${data.name}`,
    coverImage: data.coverImage,
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
    category: data.category,
    tags: []
  };
  groups.value.unshift(newGroup);
  statsData.value.totalGroups++;
  statsData.value.myGroups++;
};

// 重置过滤器
const handleResetFilters = () => {
  toast.info('过滤器已重置');
};

// 邀请成员
const handleInvite = (id: number) => {
  toast.success('邀请链接已复制到剪贴板');
};
</script>

<template>
  <div class="space-y-6">
    <!-- 统计面板 -->
    <GroupStats :stats="statsData" />

    <!-- 过滤器 -->
    <GroupFilters
      v-model="filters"
      @reset="handleResetFilters"
    />

    <!-- 群组列表 -->
    <GroupList
      :groups="filteredGroups"
      :loading="loading"
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
      :members="mockMembers"
      :posts="mockPosts"
      @join="handleJoin"
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
