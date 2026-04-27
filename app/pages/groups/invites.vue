<script setup lang="ts">
import { onMounted, ref } from 'vue';
import { toast } from 'vue-sonner';
import {
  Clock,
  CheckCircle,
  XCircle,
  Users,
  RefreshCw,
  Inbox
} from 'lucide-vue-next';
import {
  Card,
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
import {
  listMyGroupInvites,
  respondGroupInvite
} from '@/services/groups';
import type { GroupInviteView } from '@/types/groups';

const invites = ref<GroupInviteView[]>([]);
const isRefreshing = ref(false);

function formatTime(dateStr: string): string {
  const date = new Date(dateStr);
  const now = new Date();
  const diff = now.getTime() - date.getTime();
  const hours = Math.floor(diff / (1000 * 60 * 60));

  if (hours < 1) {
    const minutes = Math.floor(diff / (1000 * 60));
    return `${Math.max(minutes, 0)}分钟前`;
  }
  if (hours < 24) return `${hours}小时前`;
  return `${Math.floor(hours / 24)}天前`;
}

function getRemainingTime(expiresAt: string): string {
  const expires = new Date(expiresAt);
  const now = new Date();
  const diff = expires.getTime() - now.getTime();

  if (diff <= 0) return '已过期';

  const days = Math.floor(diff / (1000 * 60 * 60 * 24));
  const hours = Math.floor(
    (diff % (1000 * 60 * 60 * 24)) /
      (1000 * 60 * 60)
  );

  if (days > 0) return `${days}天${hours}小时后过期`;
  return `${hours}小时后过期`;
}

async function refreshInvites(): Promise<void> {
  isRefreshing.value = true;
  try {
    invites.value = await listMyGroupInvites();
  } catch (error) {
    invites.value = [];
    toast.error('加载邀请失败', {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    isRefreshing.value = false;
  }
}

async function handleAccept(id: number): Promise<void> {
  try {
    await respondGroupInvite(id, true);
    invites.value = invites.value.filter(
      invite => invite.id !== id
    );
    toast.success('已接受邀请');
  } catch (error) {
    toast.error('接受邀请失败', {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

async function handleReject(id: number): Promise<void> {
  try {
    await respondGroupInvite(id, false);
    invites.value = invites.value.filter(
      invite => invite.id !== id
    );
    toast.info('已拒绝邀请');
  } catch (error) {
    toast.error('拒绝邀请失败', {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

async function handleRefresh(): Promise<void> {
  await refreshInvites();
  toast.success('已刷新');
}

onMounted(() => {
  void refreshInvites();
});
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
