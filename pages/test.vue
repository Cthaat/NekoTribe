<template>
  <div
    class="flex h-screen w-full items-center justify-center gap-4"
  >
    <Button @click="() => toast('一个普通的 Sonner 通知')">
      普通通知
    </Button>
    <Button
      variant="destructive"
      @click="() => toast.error('一个错误的 Sonner 通知')"
    >
      错误通知
    </Button>
  </div>
  <CommentSection
    :comments="mockComments"
    :post-id="postId"
  />
</template>

<script setup lang="ts">
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button'; // 确保你的 Button 组件路径正确
import CommentSection from '@/components/CommentSection.vue';

// 在真实应用中，这些数据应该来自 useApiFetch 或类似的 API 调用
const mockComments = ref([
  {
    id: 1,
    parentCommentId: null, // parentCommentId 为 null，表示是顶级评论
    displayName: '猫部落族长',
    avatarUrl: '/avatars/user1.png',
    content: '这篇文章太棒了！学到了很多。',
    createdAt: '2025-07-19T10:00:00Z',
    likesCount: 15,
    isLikedByUser: false
  },
  {
    id: 2,
    parentCommentId: 1, // 回复 id 为 1 的评论
    displayName: 'Vue大师',
    avatarUrl: '/avatars/user2.png',
    content:
      '完全同意！特别是递归组件那部分，简直是神来之笔。',
    createdAt: '2025-07-19T10:05:00Z',
    likesCount: 7,
    isLikedByUser: true
  },
  {
    id: 3,
    parentCommentId: 2, // 回复 id 为 2 的评论
    displayName: '猫部落族长',
    avatarUrl: '/avatars/user1.png',
    content: '是吧？我已经在构思怎么把它用到我的项目里了。',
    createdAt: '2025-07-19T10:15:00Z',
    likesCount: 4,
    isLikedByUser: false
  },
  {
    id: 4,
    parentCommentId: null, // 另一条顶级评论
    displayName: '潜水观察员',
    avatarUrl: '/avatars/user3.png',
    content: '各位说的都很有道理。',
    createdAt: '2025-07-19T11:00:00Z',
    likesCount: 3,
    isLikedByUser: false
  }
]);
const postId = ref('my-awesome-post-123');
</script>
