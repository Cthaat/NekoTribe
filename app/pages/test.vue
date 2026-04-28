<script setup lang="ts">
// 无页面布局
definePageMeta({
  layout: false
});
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button'; // 确保你的 Button 组件路径正确
import CommentSection from '@/components/CommentSection.vue';
import type { CommentVM, PostAuthorVM } from '@/types/posts';

const { t } = useAppLocale();

const createMockAuthor = (
  id: number,
  username: string,
  name: string,
  avatarUrl: string
): PostAuthorVM => ({
  id,
  username,
  name,
  avatarUrl,
  bio: '',
  location: '',
  website: '',
  verified: false,
  followersCount: 0,
  followingCount: 0,
  postsCount: 0,
  likesCount: 0,
  relation: 'none'
});

// 在真实应用中，这些数据应该来自 useApiFetch 或类似的 API 调用
const mockComments = ref<CommentVM[]>([
  {
    id: 1,
    postId: 123,
    author: createMockAuthor(
      1,
      'tribe-chief',
      '猫部落族长',
      '/avatars/user1.png'
    ),
    parentCommentId: null, // parentCommentId 为 null，表示是顶级评论
    rootCommentId: null,
    content: '这篇文章太棒了！学到了很多。',
    counts: {
      likes: 15,
      replies: 1
    },
    viewer: {
      hasLiked: false,
      canDelete: false
    },
    createdAt: '2025-07-19T10:00:00Z',
    updatedAt: '2025-07-19T10:00:00Z'
  },
  {
    id: 2,
    postId: 123,
    author: createMockAuthor(
      2,
      'vue-master',
      'Vue大师',
      '/avatars/user2.png'
    ),
    parentCommentId: 1, // 回复 id 为 1 的评论
    rootCommentId: 1,
    content:
      '完全同意！特别是递归组件那部分，简直是神来之笔。',
    counts: {
      likes: 7,
      replies: 1
    },
    viewer: {
      hasLiked: true,
      canDelete: false
    },
    createdAt: '2025-07-19T10:05:00Z',
    updatedAt: '2025-07-19T10:05:00Z'
  },
  {
    id: 3,
    postId: 123,
    author: createMockAuthor(
      1,
      'tribe-chief',
      '猫部落族长',
      '/avatars/user1.png'
    ),
    parentCommentId: 2, // 回复 id 为 2 的评论
    rootCommentId: 1,
    content: '是吧？我已经在构思怎么把它用到我的项目里了。',
    counts: {
      likes: 4,
      replies: 0
    },
    viewer: {
      hasLiked: false,
      canDelete: false
    },
    createdAt: '2025-07-19T10:15:00Z',
    updatedAt: '2025-07-19T10:15:00Z'
  },
  {
    id: 4,
    postId: 123,
    author: createMockAuthor(
      3,
      'observer',
      '潜水观察员',
      '/avatars/user3.png'
    ),
    parentCommentId: null, // 另一条顶级评论
    rootCommentId: null,
    content: '各位说的都很有道理。',
    counts: {
      likes: 3,
      replies: 0
    },
    viewer: {
      hasLiked: false,
      canDelete: false
    },
    createdAt: '2025-07-19T11:00:00Z',
    updatedAt: '2025-07-19T11:00:00Z'
  }
]);

const postId = ref('my-awesome-post-123');
</script>

<template>
  <div
    class="flex h-screen w-full items-center justify-center gap-4"
  >
    <Button
      @click="() => toast(t('diagnostics.sonner.normalToast'))"
    >
      {{ t('diagnostics.sonner.normal') }}
    </Button>
    <Button
      variant="destructive"
      @click="
        () => toast.error(t('diagnostics.sonner.errorToast'))
      "
    >
      {{ t('diagnostics.sonner.error') }}
    </Button>
  </div>
  <CommentSection
    :comments="mockComments"
    :post-id="postId"
  />
</template>
