<script setup lang="ts">
import { ref, computed, watch } from 'vue';
import {
  Users,
  FileText,
  Settings,
  UserPlus,
  Share2,
  Bell,
  BellOff,
  LogOut,
  Crown,
  Globe,
  Lock,
  Shield,
  Calendar,
  MessageSquare
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
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger
} from '@/components/ui/tabs';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Separator } from '@/components/ui/separator';
import { toast } from 'vue-sonner';
import GroupMemberCard from './GroupMemberCard.vue';
import GroupPostCard from './GroupPostCard.vue';
import type {
  Group,
  GroupMember,
  GroupPost
} from '@/types/groups';
const { t, locale } = useAppLocale();
const localePath = useLocalePath();

const props = defineProps<{
  open: boolean;
  group: Group | null;
  members?: GroupMember[];
  posts?: GroupPost[];
}>();

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'join', id: number): void;
  (e: 'leave', id: number): void;
  (e: 'settings', id: number): void;
  (e: 'invite', id: number): void;
}>();

// 当前标签
const activeTab = ref('about');

// 通知状态
const notificationsEnabled = ref(true);

// 重置状态
watch(
  () => props.open,
  isOpen => {
    if (!isOpen) {
      activeTab.value = 'about';
    }
  }
);

// 获取隐私图标
const getPrivacyIcon = (privacy: string) => {
  switch (privacy) {
    case 'public':
      return Globe;
    case 'private':
      return Lock;
    case 'secret':
      return Shield;
    default:
      return Globe;
  }
};

// 获取隐私文本
const getPrivacyText = (privacy: string) => {
  switch (privacy) {
    case 'public':
      return t('groups.filters.privacy.public');
    case 'private':
      return t('groups.filters.privacy.private');
    case 'secret':
      return t('groups.filters.privacy.secret');
    default:
      return t('groups.filters.privacy.public');
  }
};

// 格式化日期
const formatDate = (dateStr: string) => {
  const date = new Date(dateStr);
  return date.toLocaleDateString(locale.value === 'zh' ? 'zh-CN' : 'en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric'
  });
};

// 处理加入/离开
const handleJoinLeave = () => {
  if (!props.group) return;
  if (props.group.isMember) {
    emit('leave', props.group.id);
  } else {
    emit('join', props.group.id);
  }
};

// 切换通知
const toggleNotifications = () => {
  notificationsEnabled.value = !notificationsEnabled.value;
  toast.success(
    notificationsEnabled.value
      ? t('groups.notifications.enabled')
      : t('groups.notifications.disabled')
  );
};

// 处理邀请
const handleInvite = () => {
  if (props.group) {
    emit('invite', props.group.id);
  }
};

// 处理设置
const handleSettings = () => {
  if (props.group) {
    emit('settings', props.group.id);
  }
};

const closeDialog = () => {
  emit('update:open', false);
};

const openMemberProfile = (userId: number) => {
  if (!Number.isFinite(userId) || userId <= 0) return;
  closeDialog();
  void navigateTo(localePath(`/user/${userId}/profile`));
};

// 切换标签
const handleTabChange = (value: string | number) => {
  activeTab.value = String(value);
};
</script>

<template>
  <Dialog :open="open" @update:open="closeDialog">
    <DialogContent
      class="max-w-2xl max-h-[90vh] overflow-hidden flex flex-col p-0"
    >
      <template v-if="group">
        <!-- 封面 -->
        <div
          class="relative h-32 bg-gradient-to-r from-primary/20 to-primary/10"
        >
          <img
            v-if="group.coverImage"
            :src="group.coverImage"
            :alt="group.name"
            class="w-full h-full object-cover"
          />
        </div>

        <!-- 头部信息 -->
        <div class="px-6 pb-4 -mt-10 relative">
          <div class="flex items-end gap-4">
            <Avatar
              class="h-20 w-20 border-4 border-background"
            >
              <AvatarImage
                :src="group.avatar"
                :alt="group.name"
              />
              <AvatarFallback class="text-2xl">{{
                group.name.charAt(0)
              }}</AvatarFallback>
            </Avatar>
            <div class="flex-1 pb-1">
              <h2 class="text-xl font-bold">
                {{ group.name }}
              </h2>
              <div
                class="flex items-center gap-2 text-sm text-muted-foreground"
              >
                <component
                  :is="getPrivacyIcon(group.privacy)"
                  class="h-4 w-4"
                />
                <span>{{
                  getPrivacyText(group.privacy)
                }}</span>
                <span>·</span>
                <span>{{ t('groups.stats.membersCount', { count: group.memberCount }) }}</span>
              </div>
            </div>
          </div>

          <!-- 操作按钮 -->
          <div class="flex items-center gap-2 mt-4">
            <Button
              v-if="!group.isOwner"
              :variant="
                group.isMember ? 'outline' : 'default'
              "
              @click="handleJoinLeave"
            >
              {{
                group.isMember
                  ? t('groups.actions.leave')
                  : group.privacy === 'public'
                    ? t('groups.actions.join')
                    : t('groups.actions.requestJoin')
              }}
            </Button>
            <Button
              v-if="group.isMember"
              variant="outline"
              @click="handleInvite"
            >
              <UserPlus class="h-4 w-4 mr-2" />
              {{ t('groups.actions.invite') }}
            </Button>
            <Button
              v-if="group.isMember"
              variant="ghost"
              size="icon"
              @click="toggleNotifications"
            >
              <component
                :is="notificationsEnabled ? Bell : BellOff"
                class="h-4 w-4"
              />
            </Button>
            <Button
              v-if="group.isOwner || group.isAdmin"
              variant="ghost"
              size="icon"
              @click="handleSettings"
            >
              <Settings class="h-4 w-4" />
            </Button>
          </div>
        </div>

        <Separator />

        <!-- 标签页 -->
        <Tabs
          :model-value="activeTab"
          class="flex-1 flex flex-col"
          @update:model-value="handleTabChange"
        >
          <TabsList class="mx-6 mt-2">
            <TabsTrigger value="about">{{ t('groups.detail.tabs.about') }}</TabsTrigger>
            <TabsTrigger value="posts">
              {{ t('groups.detail.tabs.posts', { count: posts?.length || 0 }) }}
            </TabsTrigger>
            <TabsTrigger value="members">
              {{ t('groups.detail.tabs.members', { count: members?.length || 0 }) }}
            </TabsTrigger>
          </TabsList>

          <ScrollArea class="flex-1 px-6 py-4">
            <!-- 关于 -->
            <TabsContent
              value="about"
              class="mt-0 space-y-4"
            >
              <div>
                <h3 class="font-medium mb-2">{{ t('groups.detail.aboutTitle') }}</h3>
                <p class="text-sm text-muted-foreground">
                  {{ group.description }}
                </p>
              </div>

              <Separator />

              <div class="space-y-3">
                <div
                  class="flex items-center gap-3 text-sm"
                >
                  <Calendar
                    class="h-4 w-4 text-muted-foreground"
                  />
                  <span
                    >{{ t('groups.detail.createdAt', { date: formatDate(group.createdAt) }) }}</span
                  >
                </div>
                <div
                  class="flex items-center gap-3 text-sm"
                >
                  <Users
                    class="h-4 w-4 text-muted-foreground"
                  />
                  <span
                    >{{ t('groups.stats.membersCount', { count: group.memberCount }) }}</span
                  >
                </div>
                <div
                  class="flex items-center gap-3 text-sm"
                >
                  <MessageSquare
                    class="h-4 w-4 text-muted-foreground"
                  />
                  <span>{{ t('groups.stats.posts', { count: group.postCount }) }}</span>
                </div>
              </div>

              <Separator />

              <!-- 群主信息 -->
              <div>
                <h3 class="font-medium mb-3">{{ t('groups.detail.owner') }}</h3>
                <Button
                  type="button"
                  variant="ghost"
                  class="h-auto max-w-full justify-start gap-3 px-2 py-2 text-left"
                  @click="openMemberProfile(group.owner.id)"
                >
                  <Avatar class="h-10 w-10">
                    <AvatarImage
                      :src="group.owner.avatar"
                    />
                    <AvatarFallback>{{
                      group.owner.nickname.charAt(0)
                    }}</AvatarFallback>
                  </Avatar>
                  <div>
                    <div class="flex items-center gap-2">
                      <span class="font-medium text-sm">{{
                        group.owner.nickname
                      }}</span>
                      <Badge
                        variant="default"
                        class="gap-1 text-xs"
                      >
                        <Crown class="h-3 w-3" />
                        {{ t('groups.detail.owner') }}
                      </Badge>
                    </div>
                    <span
                      class="text-xs text-muted-foreground"
                      >@{{ group.owner.username }}</span
                    >
                  </div>
                </Button>
              </div>

              <!-- 分类和标签 -->
              <div
                v-if="
                  group.category ||
                  (group.tags && group.tags.length > 0)
                "
              >
                <Separator class="mb-4" />
                <h3 class="font-medium mb-3">{{ t('groups.detail.categoryAndTags') }}</h3>
                <div class="flex flex-wrap gap-2">
                  <Badge
                    v-if="group.category"
                    variant="outline"
                  >
                    {{ group.category }}
                  </Badge>
                  <Badge
                    v-for="tag in group.tags"
                    :key="tag"
                    variant="secondary"
                  >
                    #{{ tag }}
                  </Badge>
                </div>
              </div>
            </TabsContent>

            <!-- 帖子列表 -->
            <TabsContent
              value="posts"
              class="mt-0 space-y-4"
            >
              <div
                v-if="!posts || posts.length === 0"
                class="text-center py-8 text-muted-foreground"
              >
                {{ t('groups.detail.emptyPosts') }}
              </div>
              <GroupPostCard
                v-for="post in posts"
                :key="post.id"
                :post="post"
                :can-manage="group.isOwner || group.isAdmin"
              />
            </TabsContent>

            <!-- 成员列表 -->
            <TabsContent value="members" class="mt-0">
              <div
                v-if="!members || members.length === 0"
                class="text-center py-8 text-muted-foreground"
              >
                {{ t('groups.detail.emptyMembers') }}
              </div>
              <div v-else class="space-y-1">
                <GroupMemberCard
                  v-for="member in members"
                  :key="member.id"
                  :member="member"
                  :can-manage="
                    group.isOwner || group.isAdmin
                  "
                  @view-profile="openMemberProfile"
                />
              </div>
            </TabsContent>
          </ScrollArea>
        </Tabs>
      </template>
    </DialogContent>
  </Dialog>
</template>
