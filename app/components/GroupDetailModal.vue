<script setup lang="ts">
import { ref, watch } from 'vue';
import {
  Users,
  Settings,
  UserPlus,
  Bell,
  BellOff,
  Crown,
  Globe,
  Lock,
  Shield,
  Calendar,
  MessageSquare
} from 'lucide-vue-next';
import {
  Dialog,
  DialogContent
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
import { ScrollArea } from '@/components/ui/scroll-area';
import { toast } from 'vue-sonner';
import GroupMemberCard from './GroupMemberCard.vue';
import GroupPostCard from './GroupPostCard.vue';
import {
  changeGroupMemberRole,
  getGroup,
  getGroupNotificationPreference,
  muteGroupMember,
  removeGroupMember,
  setGroupNotificationPreference,
  unmuteGroupMember
} from '@/services/groups';
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
  (e: 'updated', group: Group): void;
  (e: 'members-updated', id: number): void;
}>();

const activeTab = ref('about');

const notificationsEnabled = ref(true);
const notificationLoading = ref(false);
const notificationSaving = ref(false);
const memberActionKey = ref<string | null>(null);

watch(
  () => props.open,
  isOpen => {
    if (!isOpen) {
      activeTab.value = 'about';
    }
  }
);

watch(
  () => [props.open, props.group?.id] as const,
  async ([isOpen, groupId]) => {
    if (!isOpen || !groupId || !props.group?.isMember) {
      notificationsEnabled.value = true;
      return;
    }
    notificationLoading.value = true;
    try {
      const preference =
        await getGroupNotificationPreference(groupId);
      notificationsEnabled.value = preference.is_enabled;
    } catch {
      notificationsEnabled.value = true;
    } finally {
      notificationLoading.value = false;
    }
  },
  { immediate: true }
);

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

const getCategoryText = (category: string) =>
  t(`groups.filters.category.${category}`);

const formatDate = (dateStr: string) => {
  const date = new Date(dateStr);
  return date.toLocaleDateString(
    locale.value === 'zh' ? 'zh-CN' : 'en-US',
    {
      year: 'numeric',
      month: 'long',
      day: 'numeric'
    }
  );
};

const handleJoinLeave = () => {
  if (!props.group) return;
  if (props.group.isMember) {
    emit('leave', props.group.id);
  } else {
    emit('join', props.group.id);
  }
};

const toggleNotifications = async () => {
  if (!props.group || notificationSaving.value) return;
  const previous = notificationsEnabled.value;
  const next = !previous;
  notificationsEnabled.value = next;
  notificationSaving.value = true;
  try {
    const preference = await setGroupNotificationPreference(
      props.group.id,
      next
    );
    notificationsEnabled.value = preference.is_enabled;
    toast.success(
      preference.is_enabled
        ? t('groups.notifications.enabled')
        : t('groups.notifications.disabled')
    );
  } catch (error) {
    notificationsEnabled.value = previous;
    toast.error(t('groups.notifications.updateFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    notificationSaving.value = false;
  }
};

const handleInvite = () => {
  if (props.group) {
    emit('invite', props.group.id);
  }
};

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

function findMember(memberId: number): GroupMember | null {
  return (
    props.members?.find(member => member.id === memberId) ?? null
  );
}

async function refreshGroupAfterMemberAction(): Promise<void> {
  if (!props.group) return;
  emit('members-updated', props.group.id);
  emit('updated', await getGroup(props.group.id));
}

async function runMemberAction(
  key: string,
  action: () => Promise<void>,
  successMessage: string
): Promise<void> {
  if (!props.group || memberActionKey.value) return;
  memberActionKey.value = key;
  try {
    await action();
    toast.success(successMessage);
    await refreshGroupAfterMemberAction();
  } catch (error) {
    toast.error(t('groups.manage.feedback.memberFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    memberActionKey.value = null;
  }
}

function promoteMember(memberId: number): void {
  const member = findMember(memberId);
  if (!props.group || !member) return;
  void runMemberAction(
    `promote-${member.userId}`,
    () =>
      changeGroupMemberRole(
        props.group?.id ?? 0,
        member.userId,
        'admin'
      ),
    t('groups.member.feedback.promoted')
  );
}

function demoteMember(memberId: number): void {
  const member = findMember(memberId);
  if (!props.group || !member) return;
  void runMemberAction(
    `demote-${member.userId}`,
    () =>
      changeGroupMemberRole(
        props.group?.id ?? 0,
        member.userId,
        'member'
      ),
    t('groups.member.feedback.demoted')
  );
}

function muteMember(memberId: number): void {
  const member = findMember(memberId);
  if (!props.group || !member) return;
  void runMemberAction(
    `mute-${member.userId}`,
    () =>
      muteGroupMember(
        props.group?.id ?? 0,
        member.userId,
        24,
        t('groups.manage.defaultMuteReason')
      ),
    t('groups.member.feedback.muted')
  );
}

function unmuteMember(memberId: number): void {
  const member = findMember(memberId);
  if (!props.group || !member) return;
  void runMemberAction(
    `unmute-${member.userId}`,
    () =>
      unmuteGroupMember(
        props.group?.id ?? 0,
        member.userId
      ),
    t('groups.member.feedback.unmuted')
  );
}

function removeMember(memberId: number): void {
  const member = findMember(memberId);
  if (!props.group || !member) return;
  void runMemberAction(
    `remove-${member.userId}`,
    () =>
      removeGroupMember(
        props.group?.id ?? 0,
        member.userId
      ),
    t('groups.member.feedback.removed')
  );
}

function openPostComments(postId: number): void {
  if (!props.group) return;
  closeDialog();
  void navigateTo(
    localePath(
      `/groups/posts?group=${props.group.id}&post=${postId}&comments=1`
    )
  );
}

function openPostReport(postId: number): void {
  if (!props.group) return;
  closeDialog();
  void navigateTo(
    localePath(
      `/groups/posts?group=${props.group.id}&post=${postId}&report=1`
    )
  );
}

const handleTabChange = (value: string | number) => {
  activeTab.value = String(value);
};
</script>

<template>
  <Dialog :open="open" @update:open="closeDialog">
    <DialogContent
      class="flex max-h-[90vh] max-w-2xl flex-col overflow-hidden rounded-xl border-border/60 p-0"
    >
      <template v-if="group">
        <div
          class="relative h-32 bg-gradient-to-br from-primary/20 via-primary/10 to-background"
        >
          <img
            v-if="group.coverImage"
            :src="group.coverImage"
            :alt="group.name"
            class="h-full w-full object-cover"
          />
        </div>

        <div class="relative -mt-10 px-5 pb-4 sm:px-6">
          <div
            class="flex flex-col items-start gap-4 sm:flex-row sm:items-end"
          >
            <Avatar
              class="h-20 w-20 ring-4 ring-background shadow-md"
            >
              <AvatarImage
                :src="group.avatar"
                :alt="group.name"
              />
              <AvatarFallback
                class="bg-primary/10 text-2xl font-semibold text-primary"
              >
                {{ group.name.charAt(0) }}
              </AvatarFallback>
            </Avatar>
            <div class="min-w-0 flex-1 pb-1">
              <h2
                class="truncate text-xl font-semibold tracking-tight"
              >
                {{ group.name }}
              </h2>
              <div
                class="mt-1 flex flex-wrap items-center gap-2 text-xs text-muted-foreground"
              >
                <span
                  class="inline-flex items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 font-medium"
                >
                  <component
                    :is="getPrivacyIcon(group.privacy)"
                    class="h-3 w-3"
                  />
                  {{ getPrivacyText(group.privacy) }}
                </span>
                <span class="tabular-nums">
                  {{
                    t('groups.stats.membersCount', {
                      count: group.memberCount
                    })
                  }}
                </span>
              </div>
            </div>
          </div>

          <div
            class="mt-4 flex flex-wrap items-center gap-2"
          >
            <Button
              v-if="!group.isOwner"
              :variant="
                group.isMember ? 'outline' : 'default'
              "
              class="h-9 rounded-md shadow-xs"
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
              class="h-9 rounded-md shadow-xs"
              @click="handleInvite"
            >
              <UserPlus class="h-3.5 w-3.5" />
              {{ t('groups.actions.invite') }}
            </Button>
            <button
              v-if="group.isMember"
              type="button"
              class="flex h-9 w-9 items-center justify-center rounded-md border border-border/60 bg-background text-muted-foreground transition hover:bg-muted hover:text-foreground disabled:opacity-50"
              :disabled="notificationLoading || notificationSaving"
              :aria-label="
                notificationsEnabled
                  ? t('groups.notifications.disabled')
                  : t('groups.notifications.enabled')
              "
              @click="toggleNotifications"
            >
              <component
                :is="notificationsEnabled ? Bell : BellOff"
                class="h-3.5 w-3.5"
              />
            </button>
            <button
              v-if="group.isOwner || group.isAdmin"
              type="button"
              class="flex h-9 w-9 items-center justify-center rounded-md border border-border/60 bg-background text-muted-foreground transition hover:bg-muted hover:text-foreground"
              :aria-label="t('groups.actions.settings')"
              @click="handleSettings"
            >
              <Settings class="h-3.5 w-3.5" />
            </button>
          </div>
        </div>

        <div class="border-t border-border/60" />

        <Tabs
          :model-value="activeTab"
          class="flex flex-1 flex-col"
          @update:model-value="handleTabChange"
        >
          <div class="mx-5 mt-3 overflow-x-auto sm:mx-6">
            <TabsList
              class="grid w-max min-w-full grid-cols-3 shadow-xs"
            >
              <TabsTrigger
                value="about"
                class="text-xs font-medium"
              >
                {{ t('groups.detail.tabs.about') }}
              </TabsTrigger>
              <TabsTrigger
                value="posts"
                class="text-xs font-medium"
              >
                {{
                  t('groups.detail.tabs.posts', {
                    count: posts?.length || 0
                  })
                }}
              </TabsTrigger>
              <TabsTrigger
                value="members"
                class="text-xs font-medium"
              >
                {{
                  t('groups.detail.tabs.members', {
                    count: members?.length || 0
                  })
                }}
              </TabsTrigger>
            </TabsList>
          </div>

          <ScrollArea class="flex-1 px-5 py-4 sm:px-6">
            <TabsContent
              value="about"
              class="mt-0 grid gap-4"
            >
              <div class="grid gap-2">
                <h3
                  class="text-xs font-semibold uppercase tracking-wider text-muted-foreground"
                >
                  {{ t('groups.detail.aboutTitle') }}
                </h3>
                <p
                  class="break-words text-sm leading-6 text-foreground"
                >
                  {{ group.description }}
                </p>
              </div>

              <div class="border-t border-border/60" />

              <div class="grid gap-3">
                <div
                  class="flex items-center gap-3 text-sm"
                >
                  <span
                    class="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-muted/60 text-muted-foreground"
                  >
                    <Calendar class="h-3.5 w-3.5" />
                  </span>
                  <span class="text-muted-foreground">
                    {{
                      t('groups.detail.createdAt', {
                        date: formatDate(group.createdAt)
                      })
                    }}
                  </span>
                </div>
                <div
                  class="flex items-center gap-3 text-sm"
                >
                  <span
                    class="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
                  >
                    <Users class="h-3.5 w-3.5" />
                  </span>
                  <span class="tabular-nums text-muted-foreground">
                    {{
                      t('groups.stats.membersCount', {
                        count: group.memberCount
                      })
                    }}
                  </span>
                </div>
                <div
                  class="flex items-center gap-3 text-sm"
                >
                  <span
                    class="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
                  >
                    <MessageSquare class="h-3.5 w-3.5" />
                  </span>
                  <span class="tabular-nums text-muted-foreground">
                    {{
                      t('groups.stats.posts', {
                        count: group.postCount
                      })
                    }}
                  </span>
                </div>
              </div>

              <div class="border-t border-border/60" />

              <div class="grid gap-3">
                <h3
                  class="text-xs font-semibold uppercase tracking-wider text-muted-foreground"
                >
                  {{ t('groups.detail.owner') }}
                </h3>
                <button
                  type="button"
                  class="flex w-full items-center gap-3 rounded-lg border border-border/60 bg-card p-3 text-left transition-all hover:border-border hover:shadow-sm"
                  @click="openMemberProfile(group.owner.id)"
                >
                  <Avatar class="h-10 w-10 ring-1 ring-border">
                    <AvatarImage :src="group.owner.avatar" />
                    <AvatarFallback
                      class="bg-primary/10 text-sm font-semibold text-primary"
                    >
                      {{ group.owner.nickname.charAt(0) }}
                    </AvatarFallback>
                  </Avatar>
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2">
                      <span class="truncate text-sm font-semibold tracking-tight">
                        {{ group.owner.nickname }}
                      </span>
                      <span
                        class="inline-flex shrink-0 items-center gap-1 rounded-full border border-amber-200/60 bg-amber-100/60 px-1.5 py-0.5 text-[10px] font-medium text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300"
                      >
                        <Crown class="h-2.5 w-2.5" />
                        {{ t('groups.detail.owner') }}
                      </span>
                    </div>
                    <span class="truncate text-[11px] text-muted-foreground">
                      @{{ group.owner.username }}
                    </span>
                  </div>
                </button>
              </div>

              <div
                v-if="
                  group.category ||
                  (group.tags && group.tags.length > 0)
                "
              >
                <div class="border-t border-border/60" />
                <div class="grid gap-3 pt-4">
                  <h3
                    class="text-xs font-semibold uppercase tracking-wider text-muted-foreground"
                  >
                    {{ t('groups.detail.categoryAndTags') }}
                  </h3>
                  <div class="flex flex-wrap gap-1.5">
                    <span
                      v-if="group.category"
                      class="inline-flex items-center gap-1 rounded-full border border-primary/30 bg-primary/10 px-2 py-0.5 text-[11px] font-medium text-primary"
                    >
                      {{ getCategoryText(group.category) }}
                    </span>
                    <span
                      v-for="tag in group.tags"
                      :key="tag"
                      class="inline-flex items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 text-[11px] font-medium text-muted-foreground"
                    >
                      #{{ tag }}
                    </span>
                  </div>
                </div>
              </div>
            </TabsContent>

            <TabsContent
              value="posts"
              class="mt-0 grid gap-3"
            >
              <div
                v-if="!posts || posts.length === 0"
                class="flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-border/60 bg-muted/10 py-12 text-sm text-muted-foreground"
              >
                <span
                  class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
                >
                  <MessageSquare class="h-5 w-5" />
                </span>
                {{ t('groups.detail.emptyPosts') }}
              </div>
              <GroupPostCard
                v-for="post in posts"
                :key="post.id"
                :post="post"
                :can-manage="group.isOwner || group.isAdmin"
                @comment="openPostComments"
                @report="openPostReport"
              />
            </TabsContent>

            <TabsContent value="members" class="mt-0">
              <div
                v-if="!members || members.length === 0"
                class="flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-border/60 bg-muted/10 py-12 text-sm text-muted-foreground"
              >
                <span
                  class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
                >
                  <Users class="h-5 w-5" />
                </span>
                {{ t('groups.detail.emptyMembers') }}
              </div>
              <div v-else class="grid gap-1">
                <GroupMemberCard
                  v-for="member in members"
                  :key="member.id"
                  :member="member"
                  :can-manage="
                    group.isOwner || group.isAdmin
                  "
                  :disabled="!!memberActionKey"
                  @promote="promoteMember"
                  @demote="demoteMember"
                  @mute="muteMember"
                  @unmute="unmuteMember"
                  @remove="removeMember"
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
