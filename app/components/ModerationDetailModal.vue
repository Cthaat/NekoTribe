<script setup lang="ts">
import { ref, computed, watch } from 'vue';
import {
  Heart,
  MessageCircle,
  Repeat,
  Flag,
  CheckCircle,
  XCircle,
  Clock,
  AlertTriangle,
  User,
  Calendar,
  Eye,
  ExternalLink,
  ChevronLeft,
  ChevronRight
} from 'lucide-vue-next';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Separator } from '@/components/ui/separator';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { toast } from 'vue-sonner';
import type { ModerationTweet } from './ModerationCard.vue';

const props = defineProps<{
  open: boolean;
  tweet: ModerationTweet | null;
}>();

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'approve', id: number, note: string): void;
  (e: 'reject', id: number, note: string): void;
  (e: 'flag', id: number, note: string): void;
}>();

// 本地状态
const moderationNote = ref('');
const selectedImageIndex = ref(0);

// 重置状态
watch(
  () => props.open,
  isOpen => {
    if (!isOpen) {
      moderationNote.value = '';
      selectedImageIndex.value = 0;
    }
  }
);

// 格式化时间
const formatTime = (dateStr: string) => {
  const date = new Date(dateStr);
  return date.toLocaleString('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit'
  });
};

// 获取状态信息
const getStatusInfo = (status: string) => {
  switch (status) {
    case 'pending':
      return {
        text: '待审核',
        variant: 'secondary' as const,
        color: 'text-yellow-500'
      };
    case 'approved':
      return {
        text: '已通过',
        variant: 'default' as const,
        color: 'text-green-500'
      };
    case 'rejected':
      return {
        text: '已拒绝',
        variant: 'destructive' as const,
        color: 'text-destructive'
      };
    case 'flagged':
      return {
        text: '已标记',
        variant: 'outline' as const,
        color: 'text-orange-500'
      };
    default:
      return {
        text: '未知',
        variant: 'secondary' as const,
        color: 'text-muted-foreground'
      };
  }
};

// 举报原因详情
const reportReasonDetails: Record<
  string,
  { title: string; description: string }
> = {
  垃圾信息: {
    title: '垃圾信息/广告',
    description: '包含商业广告、垃圾链接或重复发布的内容'
  },
  骚扰: {
    title: '骚扰行为',
    description: '针对特定用户的恶意骚扰或网络欺凌'
  },
  仇恨言论: {
    title: '仇恨言论',
    description: '基于种族、性别、宗教等的歧视性言论'
  },
  暴力内容: {
    title: '暴力内容',
    description: '包含暴力威胁或血腥暴力内容'
  },
  成人内容: {
    title: '成人/色情内容',
    description: '包含色情或不适合未成年人的内容'
  },
  虚假信息: {
    title: '虚假信息',
    description: '散布虚假或误导性信息'
  }
};

// 图片导航
const prevImage = () => {
  if (props.tweet?.media && selectedImageIndex.value > 0) {
    selectedImageIndex.value--;
  }
};

const nextImage = () => {
  if (
    props.tweet?.media &&
    selectedImageIndex.value < props.tweet.media.length - 1
  ) {
    selectedImageIndex.value++;
  }
};

// 处理审核操作
const handleApprove = () => {
  if (props.tweet) {
    emit('approve', props.tweet.id, moderationNote.value);
    emit('update:open', false);
    toast.success('推文已通过审核');
  }
};

const handleReject = () => {
  if (props.tweet) {
    emit('reject', props.tweet.id, moderationNote.value);
    emit('update:open', false);
    toast.success('推文已拒绝');
  }
};

const handleFlag = () => {
  if (props.tweet) {
    emit('flag', props.tweet.id, moderationNote.value);
    emit('update:open', false);
    toast.info('推文已标记待进一步审查');
  }
};

const closeDialog = () => {
  emit('update:open', false);
};
</script>

<template>
  <Dialog :open="open" @update:open="closeDialog">
    <DialogContent
      class="max-w-3xl max-h-[90vh] overflow-hidden flex flex-col"
    >
      <DialogHeader>
        <DialogTitle class="flex items-center gap-2">
          <Eye class="h-5 w-5" />
          审核详情
        </DialogTitle>
        <DialogDescription>
          查看推文详细信息并做出审核决定
        </DialogDescription>
      </DialogHeader>

      <ScrollArea v-if="tweet" class="flex-1 pr-4">
        <div class="space-y-6">
          <!-- 用户信息区域 -->
          <div
            class="flex items-start gap-4 p-4 bg-muted/50 rounded-lg"
          >
            <Avatar class="h-14 w-14">
              <AvatarImage
                :src="tweet.author.avatar"
                :alt="tweet.author.nickname"
              />
              <AvatarFallback>{{
                tweet.author.nickname.charAt(0)
              }}</AvatarFallback>
            </Avatar>
            <div class="flex-1">
              <div class="flex items-center gap-2">
                <span class="font-semibold">{{
                  tweet.author.nickname
                }}</span>
                <span
                  v-if="tweet.author.isVerified"
                  class="text-primary"
                >
                  <CheckCircle class="h-4 w-4" />
                </span>
                <Badge
                  :variant="
                    getStatusInfo(tweet.status).variant
                  "
                >
                  {{ getStatusInfo(tweet.status).text }}
                </Badge>
              </div>
              <span class="text-sm text-muted-foreground"
                >@{{ tweet.author.username }}</span
              >
              <div
                class="flex items-center gap-4 mt-2 text-xs text-muted-foreground"
              >
                <div class="flex items-center gap-1">
                  <Calendar class="h-3 w-3" />
                  <span
                    >发布于
                    {{ formatTime(tweet.createdAt) }}</span
                  >
                </div>
                <div class="flex items-center gap-1">
                  <Flag class="h-3 w-3" />
                  <span
                    >举报于
                    {{ formatTime(tweet.reportedAt) }}</span
                  >
                </div>
              </div>
            </div>
          </div>

          <!-- 推文内容 -->
          <div>
            <h4 class="text-sm font-medium mb-2">
              推文内容
            </h4>
            <div
              class="p-4 border rounded-lg bg-background"
            >
              <p class="whitespace-pre-wrap">
                {{ tweet.content }}
              </p>
            </div>
          </div>

          <!-- 媒体内容 -->
          <div v-if="tweet.media && tweet.media.length > 0">
            <h4 class="text-sm font-medium mb-2">
              媒体内容 ({{ selectedImageIndex + 1 }}/{{
                tweet.media.length
              }})
            </h4>
            <div class="relative">
              <div
                class="aspect-video rounded-lg overflow-hidden bg-muted"
              >
                <img
                  :src="tweet.media[selectedImageIndex].url"
                  alt="媒体内容"
                  class="w-full h-full object-contain"
                />
              </div>

              <!-- 图片导航 -->
              <div
                v-if="tweet.media.length > 1"
                class="absolute inset-y-0 left-0 right-0 flex items-center justify-between px-2"
              >
                <Button
                  variant="secondary"
                  size="icon"
                  class="rounded-full opacity-80 hover:opacity-100"
                  :disabled="selectedImageIndex === 0"
                  @click="prevImage"
                >
                  <ChevronLeft class="h-4 w-4" />
                </Button>
                <Button
                  variant="secondary"
                  size="icon"
                  class="rounded-full opacity-80 hover:opacity-100"
                  :disabled="
                    selectedImageIndex ===
                    tweet.media.length - 1
                  "
                  @click="nextImage"
                >
                  <ChevronRight class="h-4 w-4" />
                </Button>
              </div>

              <!-- 缩略图导航 -->
              <div
                v-if="tweet.media.length > 1"
                class="flex gap-2 mt-2 justify-center"
              >
                <Button
                  v-for="(media, index) in tweet.media"
                  :key="index"
                  variant="ghost"
                  class="w-16 h-12 rounded overflow-hidden border-2 transition-colors"
                  :class="
                    selectedImageIndex === index
                      ? 'border-primary'
                      : 'border-transparent opacity-60 hover:opacity-100'
                  "
                  @click="selectedImageIndex = index"
                >
                  <img
                    :src="media.thumbnail || media.url"
                    alt=""
                    class="w-full h-full object-cover"
                  />
                </Button>
              </div>
            </div>
          </div>

          <!-- 举报信息 -->
          <div>
            <h4
              class="text-sm font-medium mb-2 flex items-center gap-2"
            >
              <AlertTriangle
                class="h-4 w-4 text-destructive"
              />
              举报信息 ({{ tweet.reportCount }} 次举报)
            </h4>
            <div class="space-y-2">
              <div
                v-for="reason in tweet.reportReasons"
                :key="reason"
                class="p-3 border rounded-lg bg-destructive/5"
              >
                <div class="font-medium text-sm">
                  {{
                    reportReasonDetails[reason]?.title ||
                    reason
                  }}
                </div>
                <div
                  class="text-xs text-muted-foreground mt-1"
                >
                  {{
                    reportReasonDetails[reason]
                      ?.description || '用户举报了此内容'
                  }}
                </div>
              </div>
            </div>
          </div>

          <!-- 互动数据 -->
          <div>
            <h4 class="text-sm font-medium mb-2">
              互动数据
            </h4>
            <div
              class="flex items-center gap-6 p-4 border rounded-lg"
            >
              <div class="flex items-center gap-2">
                <Heart class="h-5 w-5 text-pink-500" />
                <span class="font-medium">{{
                  tweet.likes
                }}</span>
                <span class="text-sm text-muted-foreground"
                  >喜欢</span
                >
              </div>
              <div class="flex items-center gap-2">
                <Repeat class="h-5 w-5 text-green-500" />
                <span class="font-medium">{{
                  tweet.retweets
                }}</span>
                <span class="text-sm text-muted-foreground"
                  >转发</span
                >
              </div>
              <div class="flex items-center gap-2">
                <MessageCircle
                  class="h-5 w-5 text-blue-500"
                />
                <span class="font-medium">{{
                  tweet.replies
                }}</span>
                <span class="text-sm text-muted-foreground"
                  >回复</span
                >
              </div>
            </div>
          </div>

          <Separator />

          <!-- 审核备注 -->
          <div>
            <Label
              for="moderation-note"
              class="text-sm font-medium"
              >审核备注 (可选)</Label
            >
            <Textarea
              id="moderation-note"
              v-model="moderationNote"
              placeholder="输入审核备注..."
              class="mt-2"
              rows="3"
            />
          </div>
        </div>
      </ScrollArea>

      <DialogFooter class="flex-shrink-0 gap-2 sm:gap-0">
        <Button variant="outline" @click="closeDialog">
          取消
        </Button>
        <Button
          variant="outline"
          class="text-yellow-600 hover:text-yellow-700"
          @click="handleFlag"
        >
          <Flag class="h-4 w-4 mr-2" />
          标记审查
        </Button>
        <Button variant="destructive" @click="handleReject">
          <XCircle class="h-4 w-4 mr-2" />
          拒绝
        </Button>
        <Button
          class="bg-green-600 hover:bg-green-700"
          @click="handleApprove"
        >
          <CheckCircle class="h-4 w-4 mr-2" />
          通过
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
