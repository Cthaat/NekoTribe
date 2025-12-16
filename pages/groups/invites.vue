<script setup lang="ts">
import { ref } from 'vue';
import { toast } from 'vue-sonner';
import {
  Mail,
  Clock,
  CheckCircle,
  XCircle,
  Users,
  User,
  RefreshCw,
  Inbox
} from 'lucide-vue-next';
import {
  Card,
  CardContent,
  CardFooter,
  CardHeader
} from '@/components/ui/card';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';

// 邀请类型
interface GroupInvite {
  id: number;
  group: {
    id: number;
    name: string;
    avatar: string;
    memberCount: number;
    description: string;
  };
  inviter: {
    id: number;
    username: string;
    nickname: string;
    avatar: string;
  };
  message?: string;
  createdAt: string;
  expiresAt?: string;
}

// 模拟邀请数据
const invites = ref<GroupInvite[]>([
  {
    id: 1,
    group: {
      id: 10,
      name: 'TypeScript 高级进阶',
      avatar:
        'https://api.dicebear.com/7.x/identicon/svg?seed=typescript',
      memberCount: 456,
      description:
        '深入学习 TypeScript 高级特性，类型体操训练营'
    },
    inviter: {
      id: 1,
      username: 'tsmaster',
      nickname: 'TS大师',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=tsmaster'
    },
    message:
      '看到你对 TypeScript 很感兴趣，邀请你加入我们的学习群！',
    createdAt: '2024-12-15T10:00:00Z',
    expiresAt: '2024-12-22T10:00:00Z'
  },
  {
    id: 2,
    group: {
      id: 11,
      name: '设计师交流群',
      avatar:
        'https://api.dicebear.com/7.x/identicon/svg?seed=design',
      memberCount: 789,
      description:
        'UI/UX 设计师交流平台，分享设计灵感和资源'
    },
    inviter: {
      id: 2,
      username: 'designer',
      nickname: '设计小姐姐',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=designer'
    },
    createdAt: '2024-12-14T15:00:00Z'
  },
  {
    id: 3,
    group: {
      id: 12,
      name: '创业者联盟',
      avatar:
        'https://api.dicebear.com/7.x/identicon/svg?seed=startup',
      memberCount: 234,
      description: '连接创业者，分享创业经验和资源'
    },
    inviter: {
      id: 3,
      username: 'founder',
      nickname: '连续创业者',
      avatar:
        'https://api.dicebear.com/7.x/avataaars/svg?seed=founder'
    },
    message: '我们正在招募有创业想法的朋友，期待你的加入！',
    createdAt: '2024-12-13T09:00:00Z',
    expiresAt: '2024-12-20T09:00:00Z'
  }
]);

const isRefreshing = ref(false);

// 格式化时间
const formatTime = (dateStr: string) => {
  const date = new Date(dateStr);
  const now = new Date();
  const diff = now.getTime() - date.getTime();
  const hours = Math.floor(diff / (1000 * 60 * 60));

  if (hours < 1) {
    const minutes = Math.floor(diff / (1000 * 60));
    return `${minutes}分钟前`;
  } else if (hours < 24) {
    return `${hours}小时前`;
  } else {
    const days = Math.floor(hours / 24);
    return `${days}天前`;
  }
};

// 计算剩余时间
const getRemainingTime = (expiresAt: string) => {
  const expires = new Date(expiresAt);
  const now = new Date();
  const diff = expires.getTime() - now.getTime();

  if (diff <= 0) return '已过期';

  const days = Math.floor(diff / (1000 * 60 * 60 * 24));
  const hours = Math.floor(
    (diff % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60)
  );

  if (days > 0) return `${days}天${hours}小时后过期`;
  return `${hours}小时后过期`;
};

// 接受邀请
const handleAccept = (id: number) => {
  const index = invites.value.findIndex(i => i.id === id);
  if (index !== -1) {
    const invite = invites.value[index];
    invites.value.splice(index, 1);
    toast.success(`已加入 ${invite.group.name}`);
  }
};

// 拒绝邀请
const handleReject = (id: number) => {
  const index = invites.value.findIndex(i => i.id === id);
  if (index !== -1) {
    invites.value.splice(index, 1);
    toast.info('已拒绝邀请');
  }
};

// 刷新
const handleRefresh = () => {
  isRefreshing.value = true;
  setTimeout(() => {
    isRefreshing.value = false;
    toast.success('已刷新');
  }, 1000);
};
</script>

<template>
  <div class="space-y-4">
    <!-- 头部 -->
    <div class="flex items-center justify-between">
      <div class="text-sm text-muted-foreground">
        共
        <span class="font-medium text-foreground">{{
          invites.length
        }}</span>
        条待处理邀请
      </div>
      <Button
        variant="outline"
        size="sm"
        :disabled="isRefreshing"
        @click="handleRefresh"
      >
        <RefreshCw
          :class="[
            'h-4 w-4 mr-2',
            { 'animate-spin': isRefreshing }
          ]"
        />
        刷新
      </Button>
    </div>

    <!-- 空状态 -->
    <div
      v-if="invites.length === 0"
      class="flex flex-col items-center justify-center py-16 text-center"
    >
      <div class="p-4 bg-muted rounded-full mb-4">
        <Inbox class="h-8 w-8 text-muted-foreground" />
      </div>
      <h3 class="text-lg font-medium mb-1">
        没有待处理的邀请
      </h3>
      <p class="text-sm text-muted-foreground max-w-sm">
        当有人邀请你加入群组时，邀请会显示在这里
      </p>
    </div>

    <!-- 邀请列表 -->
    <div v-else class="space-y-4">
      <Card
        v-for="invite in invites"
        :key="invite.id"
        class="hover:shadow-md transition-shadow"
      >
        <CardHeader class="pb-3">
          <div class="flex items-start gap-4">
            <!-- 群组头像 -->
            <Avatar class="h-14 w-14">
              <AvatarImage
                :src="invite.group.avatar"
                :alt="invite.group.name"
              />
              <AvatarFallback>{{
                invite.group.name.charAt(0)
              }}</AvatarFallback>
            </Avatar>

            <div class="flex-1">
              <!-- 群组信息 -->
              <div class="flex items-center gap-2">
                <h3 class="font-semibold">
                  {{ invite.group.name }}
                </h3>
                <Badge variant="secondary" class="gap-1">
                  <Users class="h-3 w-3" />
                  {{ invite.group.memberCount }}
                </Badge>
              </div>
              <p
                class="text-sm text-muted-foreground mt-1 line-clamp-2"
              >
                {{ invite.group.description }}
              </p>

              <!-- 邀请者信息 -->
              <div class="flex items-center gap-2 mt-3">
                <Avatar class="h-6 w-6">
                  <AvatarImage
                    :src="invite.inviter.avatar"
                  />
                  <AvatarFallback>{{
                    invite.inviter.nickname.charAt(0)
                  }}</AvatarFallback>
                </Avatar>
                <span class="text-sm">
                  <span class="font-medium">{{
                    invite.inviter.nickname
                  }}</span>
                  <span class="text-muted-foreground">
                    邀请你加入</span
                  >
                </span>
              </div>

              <!-- 邀请消息 -->
              <div
                v-if="invite.message"
                class="mt-3 p-3 bg-muted/50 rounded-lg text-sm italic text-muted-foreground"
              >
                "{{ invite.message }}"
              </div>
            </div>
          </div>
        </CardHeader>

        <CardFooter
          class="border-t pt-3 flex items-center justify-between"
        >
          <!-- 时间信息 -->
          <div
            class="flex items-center gap-4 text-xs text-muted-foreground"
          >
            <div class="flex items-center gap-1">
              <Clock class="h-3 w-3" />
              {{ formatTime(invite.createdAt) }}
            </div>
            <div
              v-if="invite.expiresAt"
              class="flex items-center gap-1 text-yellow-600"
            >
              <Clock class="h-3 w-3" />
              {{ getRemainingTime(invite.expiresAt) }}
            </div>
          </div>

          <!-- 操作按钮 -->
          <div class="flex items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              @click="handleReject(invite.id)"
            >
              <XCircle class="h-4 w-4 mr-1" />
              拒绝
            </Button>
            <Button
              size="sm"
              @click="handleAccept(invite.id)"
            >
              <CheckCircle class="h-4 w-4 mr-1" />
              接受
            </Button>
          </div>
        </CardFooter>
      </Card>
    </div>
  </div>
</template>
