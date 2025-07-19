<script setup lang="ts">
import { ref, computed } from 'vue';
import { toast } from 'vue-sonner';
import CommentCard from './CommentCard.vue';
import { Textarea } from '@/components/ui/textarea';
import { Button } from '@/components/ui/button';

const props = defineProps({
  // 从 API 获取的原始、扁平的评论列表
  comments: {
    type: Array,
    required: true
  },
  // 这些评论所属的文章/帖子的 ID
  postId: {
    type: [String, Number],
    required: true
  }
});

const newCommentContent = ref('');
const isSubmitting = ref(false);

/**
 * 将扁平的列表（通过 parentId 关联）转换为嵌套的树状结构。
 * 这是一个非常关键的辅助函数。
 * @param list 扁平的评论数组
 */
function flatToTree(list: any[]) {
  const map: Record<string, any> = {}; // 用于快速查找 O(1)
  const roots: any[] = []; // 存储所有顶级评论

  // 第一次遍历：将所有节点放入 map 中，并初始化 children 数组
  for (const item of list) {
    map[item.id] = { ...item, children: [] };
  }

  // 第二次遍历：将每个节点连接到其父节点上
  for (const item of list) {
    if (item.parentId) {
      // 如果是回复，找到它的父节点，并把自己加到父节点的 children 中
      map[item.parentId]?.children.push(map[item.id]);
    } else {
      // 如果是顶级评论，直接放入 roots 数组
      roots.push(map[item.id]);
    }
  }
  return roots;
}

// 这个计算属性持有最终用于渲染的、嵌套好的评论树
const nestedComments = computed(() =>
  flatToTree(props.comments)
);

// --- API 调用处理器 ---

async function handleLikeComment({
  id
}: {
  id: string | number;
}) {
  console.log(`正在点赞评论，ID: ${id}`);
  // TODO: 在这里实现您的点赞 API 调用
  // await apiFetch(`/api/v1/comments/${id}/like`, { method: 'POST' });
  toast.info(`已为评论 ${id} 进行乐观更新。需要接入 API。`);
}

async function handleSubmitReply({
  parentId,
  content
}: {
  parentId: string | number;
  content: string;
}) {
  console.log(
    `正在回复评论 ${parentId}，内容: "${content}"`
  );
  isSubmitting.value = true;
  try {
    // TODO: 在这里实现您的回复 API 调用
    // const newComment = await apiFetch('/api/v1/comments/create', {
    //   method: 'POST',
    //   body: { postId: props.postId, parentId, content }
    // });
    toast.success(
      `已提交对评论 ${parentId} 的回复。成功后应刷新评论列表。`
    );
    // 理想情况下，API 返回新评论后，您可以将其添加到 `props.comments` 中实现乐观更新
  } catch (err) {
    toast.error('提交回复失败。');
  } finally {
    isSubmitting.value = false;
  }
}

async function handleSubmitTopLevelComment() {
  if (!newCommentContent.value.trim()) return;
  console.log(
    `正在提交顶级评论: "${newCommentContent.value}"`
  );
  isSubmitting.value = true;
  try {
    // TODO: 在这里实现您的创建顶级评论的 API 调用
    // await apiFetch('/api/v1/comments/create', {
    //   method: 'POST',
    //   body: { postId: props.postId, content: newCommentContent.value }
    // });
    toast.success('顶级评论已提交。成功后应刷新评论列表。');
    newCommentContent.value = '';
  } catch (err) {
    toast.error('提交评论失败。');
  } finally {
    isSubmitting.value = false;
  }
}
</script>

<template>
  <div class="w-full max-w-3xl mx-auto p-4 font-sans">
    <h2 class="text-2xl font-bold mb-4">
      评论区 ({{ comments.length }})
    </h2>

    <!-- 发表顶级评论的表单 -->
    <div class="mb-6">
      <Textarea
        v-model="newCommentContent"
        placeholder="写下你的评论..."
        class="mb-2"
      />
      <Button
        @click="handleSubmitTopLevelComment"
        :disabled="isSubmitting"
      >
        {{ isSubmitting ? '正在发布...' : '发布评论' }}
      </Button>
    </div>

    <!-- 评论列表的渲染从此开始 -->
    <div v-if="nestedComments.length > 0" class="space-y-2">
      <CommentCard
        v-for="comment in nestedComments"
        :key="comment.id"
        :comment="comment"
        :level="0"
        @like-comment="handleLikeComment"
        @submit-reply="handleSubmitReply"
      />
    </div>
    <div
      v-else
      class="text-center text-muted-foreground py-8"
    >
      还没有人评论，快来抢占第一个沙发吧！
    </div>
  </div>
</template>
