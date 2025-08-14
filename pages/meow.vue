<script setup lang="ts">
import { useApiFetch } from '@/composables/useApiFetch';
import { toast } from 'vue-sonner';
// 1. 导入 Separator 和 Button (如果它们还没被自动导入)
import { Separator } from '@/components/ui/separator';
import { Button } from '@/components/ui/button';
import { apiFetch } from '@/composables/useApi';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription
} from '@/components/ui/dialog';

// 2. 导入我们功能强大的推文编辑器组件
import TweetComposer from '@/components/TweetComposer.vue';

interface PreviewTweet {
  tweetId: number;
  author: {
    displayName: string;
    username: string;
    avatarUrl: string;
  };
  content: string;
}

const isQuoteDialogOpen = ref(false);
const isReplyDialogOpen = ref(false);
const tweetToQuote = ref<PreviewTweet | undefined>(
  undefined
);
const tweetToReply = ref<PreviewTweet | undefined>(
  undefined
);

const selectableTweets = ref<PreviewTweet[]>([]); // 存储从 API 获取的推文
const isDialogLoading = ref(false); // 控制 Dialog 内部的加载状态
const dialogError = ref<string | null>(null); // 存储 Dialog 获取数据的错误信息

function handleSelectQuote(tweet: PreviewTweet) {
  tweetToQuote.value = tweet;
  tweetToReply.value = undefined;
  isQuoteDialogOpen.value = false;
}
function handleSelectReply(tweet: PreviewTweet) {
  tweetToReply.value = tweet;
  tweetToQuote.value = undefined;
  isReplyDialogOpen.value = false;
}

watch(isQuoteDialogOpen, async isOpen => {
  // 我们只在 Dialog 打开时执行操作，并且仅当列表为空时才获取 (避免重复获取)
  if (isOpen && selectableTweets.value.length === 0) {
    console.log('引用 Dialog 已打开，开始获取推文列表...');
    isDialogLoading.value = true;
    dialogError.value = null;

    try {
      // TODO: 在真实应用中，这里会是一个 API 调用
      // 我们用 setTimeout 来模拟一个网络延迟
      await new Promise(resolve =>
        setTimeout(resolve, 1000)
      );

      // 模拟 API 成功返回的数据
      selectableTweets.value = [
        {
          tweetId: 1001,
          author: {
            displayName: '小明',
            username: 'ming',
            avatarUrl: '/avatars/01.png'
          },
          content:
            '今天天气真不错！阳光明媚，适合出去走走。'
        },
        {
          tweetId: 1002,
          author: {
            displayName: '小红',
            username: 'hong',
            avatarUrl: '/avatars/02.png'
          },
          content:
            '刚刚发布了我的新项目 NekoTribe，它是一个基于 Nuxt 和 Vue 构建的社交平台，快来看看吧！'
        },
        {
          tweetId: 1003,
          author: {
            displayName: '李华',
            username: 'lihua',
            avatarUrl: '/avatars/03.png'
          },
          content:
            '深夜还在修复 Bug，程序员的浪漫你们不懂。 #加班'
        }
      ];
    } catch (err) {
      console.error('获取可引用推文失败:', err);
      dialogError.value = '无法加载推文列表，请稍后再试。';
    } finally {
      isDialogLoading.value = false;
    }
  }
});

watch(isReplyDialogOpen, async isOpen => {
  // 我们只在 Dialog 打开时执行操作，并且仅当列表为空时才获取 (避免重复获取)
  if (isOpen && selectableTweets.value.length === 0) {
    console.log('回复 Dialog 已打开，开始获取推文列表...');
    isDialogLoading.value = true;
    dialogError.value = null;

    try {
      // 在真实应用中，这里会是一个 API 调用
      // 我们用 setTimeout 来模拟一个网络延迟
      await new Promise(resolve =>
        setTimeout(resolve, 1000)
      );

      // 模拟 API 成功返回的数据
      selectableTweets.value = [
        {
          tweetId: 1001,
          author: {
            displayName: '小明',
            username: 'ming',
            avatarUrl: '/avatars/01.png'
          },
          content:
            '今天天气真不错！阳光明媚，适合出去走走。'
        },
        {
          tweetId: 1002,
          author: {
            displayName: '小红',
            username: 'hong',
            avatarUrl: '/avatars/02.png'
          },
          content:
            '刚刚发布了我的新项目 NekoTribe，它是一个基于 Nuxt 和 Vue 构建的社交平台，快来看看吧！'
        },
        {
          tweetId: 1003,
          author: {
            displayName: '李华',
            username: 'lihua',
            avatarUrl: '/avatars/03.png'
          },
          content:
            '深夜还在修复 Bug，程序员的浪漫你们不懂。 #加班'
        }
      ];
    } catch (err) {
      console.error('获取可回复推文失败:', err);
      dialogError.value = '无法加载推文列表，请稍后再试。';
    } finally {
      isDialogLoading.value = false;
    }
  }
});

const isSubmitting = ref(false); // 控制提交状态
const submissionError = ref<string | null>(null); // 存储提交错误信息
// 3. 【核心修改】创建 handleTweetSubmit 方法来处理子组件上报的数据
async function handleTweetSubmit(
  submitForm: any,
  formData: any
) {
  console.log(
    '父组件已收到 FormData，准备提交。其内容如下：'
  );

  // 【核心修复】使用 for...of 循环来打印 FormData 的内容
  for (const [key, value] of formData.entries()) {
    console.log(`${key}:`, value);
  }

  console.log('推文内容:', submitForm);

  isSubmitting.value = true;
  submissionError.value = null;

  try {
    // 在这里执行真正的 API 调用
    const response: any = await apiFetch(
      '/api/v1/tweets/send-tweets',
      {
        method: 'POST',
        body: submitForm.value
      }
    );

    if (!response.success) {
      throw new Error(`提交失败: ${response.statusText}`);
    }

    formData.append('tweetId', response.data.tweetId);

    const responseFiles: any = await apiFetch(
      '/api/v1/tweets/media/upload',
      {
        method: 'POST',
        body: formData
      }
    );

    toast.success('推文发布成功！');

    // 可以在这里执行成功后的操作，比如清空编辑器或跳转页面
    // (清空编辑器的逻辑最好还是放在 TweetComposer 内部，父组件可以调用一个子组件的方法来实现)
  } catch (err: any) {
    console.error('推文提交失败:', err);
    submissionError.value =
      err.data?.message || '发生未知错误，请稍后再试。';
    toast.error(`发布失败: ${submissionError.value}`);
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
              发布推文
            </h2>
            <p class="text-muted-foreground text-sm mt-1">
              分享你的想法，与世界连接。
            </p>
          </div>
          <!-- TODO: 这个按钮可以链接到草稿箱或执行其他操作 -->
          <!-- <Button variant="secondary">查看草稿</Button> -->
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
              >选择要引用的推文</DialogTitle
            >
            <DialogDescription
              >从下面的列表中选择一条推文来添加到你的引用中。</DialogDescription
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
                正在加载推文...
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
              <p>没有找到可供引用的推文。</p>
            </div>

            <!-- 4. 成功状态 -->
            <div v-else class="grid gap-4">
              <div
                v-for="tweet in selectableTweets"
                :key="tweet.tweetId"
                class="p-3 border border-gray-800 rounded-lg hover:bg-gray-800/50 cursor-pointer transition-colors"
                @click="handleSelectQuote(tweet)"
              >
                <div class="flex items-center text-sm mb-2">
                  <img
                    :src="tweet.author.avatarUrl"
                    class="h-5 w-5 rounded-full mr-2"
                  />
                  <span class="font-bold text-gray-200">{{
                    tweet.author.displayName
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
              >选择要回复的推文</DialogTitle
            >
            <DialogDescription
              >从下面的列表中选择一条推文来添加到你的回复中。</DialogDescription
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
                正在加载推文...
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
              <p>没有找到可供回复的推文。</p>
            </div>

            <!-- 4. 成功状态 -->
            <div v-else class="grid gap-4">
              <div
                v-for="tweet in selectableTweets"
                :key="tweet.tweetId"
                class="p-3 border border-gray-800 rounded-lg hover:bg-gray-800/50 cursor-pointer transition-colors"
                @click="handleSelectReply(tweet)"
              >
                <div class="flex items-center text-sm mb-2">
                  <img
                    :src="tweet.author.avatarUrl"
                    class="h-5 w-5 rounded-full mr-2"
                  />
                  <span class="font-bold text-gray-200">{{
                    tweet.author.displayName
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
      text="正在发布推文..."
    />
  </div>
</template>
