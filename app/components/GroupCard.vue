<script setup lang="ts">
import { computed } from 'vue';
import {
  Users,
  Lock,
  Globe,
  Shield,
  MoreHorizontal,
  UserPlus,
  LogOut,
  Settings,
  Eye
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
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
import type { Group } from '@/types/groups';

export type { Group } from '@/types/groups';

const props = defineProps<{
  group: Group;
}>();

const emit = defineEmits<{
  (e: 'join', id: number): void;
  (e: 'leave', id: number): void;
  (e: 'view-detail', group: Group): void;
  (e: 'settings', id: number): void;
}>();

// 获取隐私图标
const privacyIcon = computed(() => {
  switch (props.group.privacy) {
    case 'public':
      return Globe;
    case 'private':
      return Lock;
    case 'secret':
      return Shield;
    default:
      return Globe;
  }
});

// 获取隐私文本
const privacyText = computed(() => {
  switch (props.group.privacy) {
    case 'public':
      return '公开群组';
    case 'private':
      return '私密群组';
    case 'secret':
      return '隐秘群组';
    default:
      return '公开群组';
  }
});

// 格式化成员数量
const formatMemberCount = (count: number) => {
  if (count >= 10000) {
    return `${(count / 10000).toFixed(1)}万`;
  } else if (count >= 1000) {
    return `${(count / 1000).toFixed(1)}千`;
  }
  return count.toString();
};

// 处理加入/离开
const handleJoinLeave = () => {
  if (props.group.isMember) {
    emit('leave', props.group.id);
  } else {
    emit('join', props.group.id);
  }
};

const handleViewDetail = () => {
  emit('view-detail', props.group);
};

const handleSettings = () => {
  emit('settings', props.group.id);
};
</script>

<template>
  <Card
    class="overflow-hidden hover:shadow-lg transition-shadow cursor-pointer"
    @click="handleViewDetail"
  >
    <!-- 封面图片 -->
    <div
      class="relative h-24 bg-gradient-to-r from-primary/20 to-primary/10"
    >
      <img
        v-if="group.coverImage"
        :src="group.coverImage"
        :alt="group.name"
        class="w-full h-full object-cover"
      />
      <!-- 隐私徽章 -->
      <Badge
        variant="secondary"
        class="absolute top-2 right-2 gap-1"
      >
        <component :is="privacyIcon" class="h-3 w-3" />
        {{ privacyText }}
      </Badge>
    </div>

    <CardHeader class="relative pb-2">
      <!-- 群组头像 -->
      <Avatar
        class="absolute -top-8 left-4 h-16 w-16 border-4 border-background"
      >
        <AvatarImage
          :src="group.avatar"
          :alt="group.name"
        />
        <AvatarFallback>{{
          group.name.charAt(0)
        }}</AvatarFallback>
      </Avatar>

      <!-- 操作按钮 -->
      <div class="flex justify-end">
        <DropdownMenu>
          <DropdownMenuTrigger as-child @click.stop>
            <Button
              variant="ghost"
              size="icon"
              class="h-8 w-8"
            >
              <MoreHorizontal class="h-4 w-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem
              @click.stop="handleViewDetail"
            >
              <Eye class="h-4 w-4 mr-2" />
              查看详情
            </DropdownMenuItem>
            <DropdownMenuSeparator
              v-if="group.isOwner || group.isAdmin"
            />
            <DropdownMenuItem
              v-if="group.isOwner || group.isAdmin"
              @click.stop="handleSettings"
            >
              <Settings class="h-4 w-4 mr-2" />
              群组设置
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>

      <!-- 群组名称和描述 -->
      <div class="mt-4">
        <h3 class="font-semibold text-lg line-clamp-1">
          {{ group.name }}
        </h3>
        <p
          class="text-sm text-muted-foreground line-clamp-2 mt-1"
        >
          {{ group.description }}
        </p>
      </div>
    </CardHeader>

    <CardContent class="pb-3">
      <!-- 分类和标签 -->
      <div
        v-if="
          group.category ||
          (group.tags && group.tags.length > 0)
        "
        class="flex flex-wrap gap-1 mb-3"
      >
        <Badge
          v-if="group.category"
          variant="outline"
          class="text-xs"
        >
          {{ group.category }}
        </Badge>
        <Badge
          v-for="tag in group.tags?.slice(0, 3)"
          :key="tag"
          variant="secondary"
          class="text-xs"
        >
          #{{ tag }}
        </Badge>
      </div>

      <!-- 统计信息 -->
      <div
        class="flex items-center gap-4 text-sm text-muted-foreground"
      >
        <div class="flex items-center gap-1">
          <Users class="h-4 w-4" />
          <span
            >{{
              formatMemberCount(group.memberCount)
            }}
            成员</span
          >
        </div>
        <div class="flex items-center gap-1">
          <span>{{ group.postCount }} 帖子</span>
        </div>
      </div>
    </CardContent>

    <CardFooter class="border-t pt-3" @click.stop>
      <Button
        v-if="!group.isOwner"
        :variant="group.isMember ? 'outline' : 'default'"
        class="w-full"
        @click="handleJoinLeave"
      >
        <component
          :is="group.isMember ? LogOut : UserPlus"
          class="h-4 w-4 mr-2"
        />
        {{
          group.isMember
            ? '离开群组'
            : group.privacy === 'public'
              ? '加入群组'
              : '申请加入'
        }}
      </Button>
      <Button
        v-else
        variant="outline"
        class="w-full"
        @click="handleSettings"
      >
        <Settings class="h-4 w-4 mr-2" />
        管理群组
      </Button>
    </CardFooter>
  </Card>
</template>
