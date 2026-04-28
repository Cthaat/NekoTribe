<script setup lang="ts">
import type {
  CreatePostFormVM,
  PreviewPostVM
} from '@/types/posts';
import {
  v2CreatePost,
  v2ListPostPreviews,
  v2UploadMedia
} from '@/services';
import { toast } from 'vue-sonner';
import { Separator } from '@/components/ui/separator';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription
} from '@/components/ui/dialog';

import TweetComposer from '@/components/TweetComposer.vue';
const localePath = useLocalePath();
const { t } = useAppLocale();

const isQuoteDialogOpen = ref(false);
const isReplyDialogOpen = ref(false);
const tweetToQuote = ref<PreviewPostVM | undefined>(
  undefined
);
const tweetToReply = ref<PreviewPostVM | undefined>(
  undefined
);

const selectableTweets = ref<PreviewPostVM[]>([]); // 存储从 API 获取的推文
const isDialogLoading = ref(false); // 控制 Dialog 内部的加载状态
const dialogError = ref<string | null>(null); // 存储 Dialog 获取数据的错误信息

function handleSelectQuote(tweet: PreviewPostVM) {
  tweetToQuote.value = tweet;
  tweetToReply.value = undefined;
  isQuoteDialogOpen.value = false;
}
function handleSelectReply(tweet: PreviewPostVM) {
  tweetToReply.value = tweet;
  tweetToQuote.value = undefined;
  isReplyDialogOpen.value = false;
}

async function loadSelectableTweets(): Promise<void> {
  isDialogLoading.value = true;
  dialogError.value = null;

  try {
    const result = await v2ListPostPreviews({
      page: 1,
      pageSize: 10,
      sort: 'newest',
      timeline: 'home'
    });
    selectableTweets.value = result.items;
  } catch (err) {
    console.error('获取可选择推文失败:', err);
    dialogError.value = t('post.composePage.loadSelectableFailed');
  } finally {
    isDialogLoading.value = false;
  }
}

watch(isQuoteDialogOpen, async isOpen => {
  if (isOpen && selectableTweets.value.length === 0) {
    await loadSelectableTweets();
  }
});

watch(isReplyDialogOpen, async isOpen => {
  if (isOpen && selectableTweets.value.length === 0) {
    await loadSelectableTweets();
  }
});

const isSubmitting = ref(false); // 控制提交状态
const submissionError = ref<string | null>(null); // 存储提交错误信息
// 3. 【核心修改】创建 handleTweetSubmit 方法来处理子组件上报的数据
async function handleTweetSubmit(
  submitForm: CreatePostFormVM,
  formData: FormData
) {
  isSubmitting.value = true;
  submissionError.value = null;

  try {
    const mediaIds: number[] = [];
    const fileEntries = formData.getAll('file');
    const altText = String(formData.get('altText') || '');

    for (const entry of fileEntries) {
      if (!(entry instanceof File)) {
        continue;
      }
      const mediaFormData = new FormData();
      mediaFormData.append('file', entry);
      if (altText) {
        mediaFormData.append('alt_text', altText);
      }
      const media = await v2UploadMedia(mediaFormData);
      mediaIds.push(media.media_id);
    }

    await v2CreatePost({
      ...submitForm,
      mediaIds
    });

    toast.success(t('post.composePage.publishSuccess'));

    // 跳转到推文页
    await navigateTo(localePath('/'));

    // 可以在这里执行成功后的操作，比如清空编辑器或跳转页面
    // (清空编辑器的逻辑最好还是放在 TweetComposer 内部，父组件可以调用一个子组件的方法来实现)
  } catch (err) {
    console.error('推文提交失败:', err);
    submissionError.value =
      err instanceof Error
        ? err.message
        : t('post.composePage.submitUnknownError');
    toast.error(
      t('post.composePage.publishFailed', {
        message: submissionError.value
      })
    );
  } finally {
    isSubmitting.value = false;
  }
}
</script>

<template>
  <div class="relative min-h-screen">
    <!-- 
    我们将移除外层的 `hidden md:block`，让页面在所有设备上都可见。
    并调整一些间距，让布局更和谐。
  -->
    <div class="space-y-6 p-4 sm:p-8">
      <!-- 让标题与输入框左侧对齐：使用与编辑器相同的容器 -->
      <div class="mx-auto max-w-3xl">
        <div
          class="flex items-center justify-between padding-bottom-4"
        >
          <div>
            <h2 class="text-2xl font-bold tracking-tight">
              {{ t('post.composePage.title') }}
            </h2>
            <p class="text-muted-foreground text-sm mt-1">
              {{ t('post.composePage.description') }}
            </p>
          </div>
        </div>

        <!-- 分割线（也放入相同容器中以保持对齐） -->
        <Separator class="my-6" />
      </div>

      <!-- 
      3. 【核心修改】在分割线下方，直接放置我们的推文编辑器组件。
         我们将移除编辑器内部的 Card 样式，让它直接融入当前页面。
         为此，我们需要给它传递一个 prop。
    -->
      <div class="mx-auto max-w-3xl">
        <!-- 
         为了让 TweetComposer 更好地融入页面，
         我们可以给它传递一个 prop 来控制是否显示 Card 样式。
         这需要对 TweetComposer 做一个小小的修改。
       -->
        <TweetComposer
          @open-quote-dialog="isQuoteDialogOpen = true"
          @open-reply-dialog="isReplyDialogOpen = true"
          @submit="handleTweetSubmit"
          :quote-to="tweetToQuote"
          :reply-to="tweetToReply"
        />
      </div>
      <!-- TODO: 未来可以把Dialog单独抽取为一个组件 -->
      <!-- “引用推文” Dialog -->
      <Dialog v-model:open="isQuoteDialogOpen">
        <DialogContent
          class="sm:max-w-lg bg-background border-gray-700"
        >
          <DialogHeader>
            <DialogTitle class="text-white"
              >{{ t('post.composePage.quote.title') }}</DialogTitle
            >
            <DialogDescription
              >{{
                t('post.composePage.quote.description')
              }}</DialogDescription
            >
          </DialogHeader>

          <!-- 【核心修改】根据数据状态显示不同的内容 -->
          <div class="py-4 max-h-[60vh] overflow-y-auto">
            <!-- 1. 加载状态 -->
            <div
              v-if="isDialogLoading"
              class="flex items-center justify-center h-48"
            >
              <p class="text-muted-foreground">
                {{ t('post.composePage.dialog.loading') }}
              </p>
              <!-- 你也可以在这里放一个旋转的加载图标 -->
            </div>

            <!-- 2. 错误状态 -->
            <div
              v-else-if="dialogError"
              class="text-center text-destructive"
            >
              <p>{{ dialogError }}</p>
            </div>

            <!-- 3. 空状态 -->
            <div
              v-else-if="selectableTweets.length === 0"
              class="text-center text-muted-foreground"
            >
              <p>{{ t('post.composePage.quote.empty') }}</p>
            </div>

            <!-- 4. 成功状态 -->
            <div v-else class="grid gap-4">
              <div
                v-for="tweet in selectableTweets"
                :key="tweet.id"
                class="p-3 border border-gray-800 rounded-lg hover:bg-gray-800/50 cursor-pointer transition-colors"
                @click="handleSelectQuote(tweet)"
              >
                <div class="flex items-center text-sm mb-2">
                  <img
                    :src="tweet.author.avatarUrl"
                    class="h-5 w-5 rounded-full mr-2"
                  />
                  <span class="font-bold text-gray-200">{{
                    tweet.author.name
                  }}</span>
                  <span class="ml-1 text-gray-500"
                    >@{{ tweet.author.username }}</span
                  >
                </div>
                <p
                  class="text-gray-400 text-sm leading-snug"
                >
                  {{ tweet.content }}
                </p>
              </div>
            </div>
          </div>
        </DialogContent>
      </Dialog>

      <Dialog v-model:open="isReplyDialogOpen">
        <DialogContent
          class="sm:max-w-lg bg-background border-gray-700"
        >
          <DialogHeader>
            <DialogTitle class="text-white"
              >{{ t('post.composePage.reply.title') }}</DialogTitle
            >
            <DialogDescription
              >{{
                t('post.composePage.reply.description')
              }}</DialogDescription
            >
          </DialogHeader>

          <!-- 【核心修改】根据数据状态显示不同的内容 -->
          <div class="py-4 max-h-[60vh] overflow-y-auto">
            <!-- 1. 加载状态 -->
            <div
              v-if="isDialogLoading"
              class="flex items-center justify-center h-48"
            >
              <p class="text-muted-foreground">
                {{ t('post.composePage.dialog.loading') }}
              </p>
              <!-- 你也可以在这里放一个旋转的加载图标 -->
            </div>

            <!-- 2. 错误状态 -->
            <div
              v-else-if="dialogError"
              class="text-center text-destructive"
            >
              <p>{{ dialogError }}</p>
            </div>

            <!-- 3. 空状态 -->
            <div
              v-else-if="selectableTweets.length === 0"
              class="text-center text-muted-foreground"
            >
              <p>{{ t('post.composePage.reply.empty') }}</p>
            </div>

            <!-- 4. 成功状态 -->
            <div v-else class="grid gap-4">
              <div
                v-for="tweet in selectableTweets"
                :key="tweet.id"
                class="p-3 border border-gray-800 rounded-lg hover:bg-gray-800/50 cursor-pointer transition-colors"
                @click="handleSelectReply(tweet)"
              >
                <div class="flex items-center text-sm mb-2">
                  <img
                    :src="tweet.author.avatarUrl"
                    class="h-5 w-5 rounded-full mr-2"
                  />
                  <span class="font-bold text-gray-200">{{
                    tweet.author.name
                  }}</span>
                  <span class="ml-1 text-gray-500"
                    >@{{ tweet.author.username }}</span
                  >
                </div>
                <p
                  class="text-gray-400 text-sm leading-snug"
                >
                  {{ tweet.content }}
                </p>
              </div>
            </div>
          </div>
        </DialogContent>
      </Dialog>
    </div>
    <LoadingOverlay
      v-if="isSubmitting"
      :text="t('post.composePage.submitting')"
    />
  </div>
</template>



