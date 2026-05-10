<script setup lang="ts">
import { computed, reactive, ref, shallowRef, watch } from 'vue';
import {
  Check,
  Clock,
  Copy,
  Crown,
  Link,
  RefreshCw,
  Save,
  Search,
  Trash2,
  UserMinus,
  Volume2,
  VolumeX,
  X
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
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Separator } from '@/components/ui/separator';
import { Switch } from '@/components/ui/switch';
import { Textarea } from '@/components/ui/textarea';
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger
} from '@/components/ui/tooltip';
import { toast } from 'vue-sonner';
import {
  approveGroupMember,
  changeGroupMemberRole,
  createGroupInviteData,
  deleteGroup,
  getGroup,
  listGroupInvites,
  listGroupMembers,
  muteGroupMember,
  removeGroupMember,
  transferGroupOwnership,
  unmuteGroupMember,
  updateGroup
} from '@/services/groups';
import type {
  Group,
  GroupMember,
  GroupPrivacy,
  GroupRole,
  UpdateGroupData
} from '@/types/groups';
import type {
  V2GroupInvite,
  V2GroupPostPermission
} from '@/types/v2';

const props = defineProps<{
  open: boolean;
  group: Group | null;
}>();

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'updated', group: Group): void;
  (e: 'deleted', groupId: number): void;
}>();

const { t, locale } = useAppLocale();

const activeTab = ref('settings');
const members = shallowRef<GroupMember[]>([]);
const invites = shallowRef<V2GroupInvite[]>([]);
const memberSearch = ref('');
const deleteConfirm = ref('');
const inviteMaxUses = ref(100);
const inviteExpireHours = ref(168);
const loadingMembers = ref(false);
const loadingInvites = ref(false);
const saving = ref(false);
const deleting = ref(false);
const creatingInvite = ref(false);
const actionKey = ref<string | null>(null);

const form = reactive<UpdateGroupData>({
  name: '',
  description: '',
  avatar: '',
  coverImage: '',
  privacy: 'public',
  joinApproval: false,
  postPermission: 'all'
});

const privacyOptions: Array<{
  value: GroupPrivacy;
  labelKey: string;
}> = [
  { value: 'public', labelKey: 'groups.filters.privacy.public' },
  { value: 'private', labelKey: 'groups.filters.privacy.private' },
  { value: 'secret', labelKey: 'groups.filters.privacy.secret' }
];

const postPermissionOptions: Array<{
  value: V2GroupPostPermission;
  labelKey: string;
}> = [
  {
    value: 'all',
    labelKey: 'groups.manage.postPermission.all'
  },
  {
    value: 'moderator_up',
    labelKey: 'groups.manage.postPermission.moderator_up'
  },
  {
    value: 'admin_only',
    labelKey: 'groups.manage.postPermission.admin_only'
  }
];

const roleOptions: Array<{
  value: Exclude<GroupRole, 'owner'>;
  labelKey: string;
}> = [
  { value: 'member', labelKey: 'groups.member.roles.member' },
  {
    value: 'moderator',
    labelKey: 'groups.member.roles.moderator'
  },
  { value: 'admin', labelKey: 'groups.member.roles.admin' }
];

const canEditSettings = computed(
  () =>
    props.group?.isOwner ||
    props.group?.membershipRole === 'admin'
);
const canModerateMembers = computed(
  () =>
    canEditSettings.value ||
    props.group?.membershipRole === 'moderator'
);
const canTransferOwnership = computed(
  () => props.group?.isOwner === true
);

const pendingMembers = computed(() =>
  members.value.filter(member => member.status === 'pending')
);

const managedMembers = computed(() => {
  const query = memberSearch.value.trim().toLowerCase();
  const activeMembers = members.value.filter(
    member => member.status !== 'pending'
  );
  if (!query) return activeMembers;
  return activeMembers.filter(
    member =>
      member.nickname.toLowerCase().includes(query) ||
      member.username.toLowerCase().includes(query)
  );
});

const activeMemberCount = computed(
  () => props.group?.memberCount ?? 0
);

function resetForm(group: Group): void {
  form.name = group.name;
  form.description = group.description;
  form.avatar = group.avatar;
  form.coverImage = group.coverImage ?? '';
  form.privacy = group.privacy;
  form.joinApproval = group.joinApproval;
  form.postPermission = group.postPermission;
  deleteConfirm.value = '';
  memberSearch.value = '';
  activeTab.value = 'settings';
}

async function refreshGroup(): Promise<void> {
  if (!props.group) return;
  const updated = await getGroup(props.group.id);
  emit('updated', updated);
}

async function loadMembers(): Promise<void> {
  if (!props.group) return;
  loadingMembers.value = true;
  try {
    members.value = await listGroupMembers(props.group.id);
  } catch (error) {
    toast.error(t('groups.manage.feedback.loadMembersFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    loadingMembers.value = false;
  }
}

async function loadInvites(): Promise<void> {
  if (!props.group || !canModerateMembers.value) {
    invites.value = [];
    return;
  }
  loadingInvites.value = true;
  try {
    invites.value = await listGroupInvites(props.group.id);
  } catch (error) {
    toast.error(t('groups.manage.feedback.loadInvitesFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    loadingInvites.value = false;
  }
}

async function reloadManagementData(): Promise<void> {
  await Promise.all([loadMembers(), loadInvites()]);
}

watch(
  () => [props.open, props.group?.id] as const,
  async ([isOpen]) => {
    if (!isOpen || !props.group) return;
    resetForm(props.group);
    await reloadManagementData();
  }
);

function updatePrivacy(value: unknown): void {
  const next = String(value);
  if (
    next === 'public' ||
    next === 'private' ||
    next === 'secret'
  ) {
    form.privacy = next;
  }
}

function updatePostPermission(value: unknown): void {
  const next = String(value);
  if (
    next === 'all' ||
    next === 'admin_only' ||
    next === 'moderator_up'
  ) {
    form.postPermission = next;
  }
}

function updateMemberRole(
  member: GroupMember,
  value: unknown
): void {
  const next = String(value);
  if (
    next !== 'admin' &&
    next !== 'moderator' &&
    next !== 'member'
  ) {
    return;
  }
  void runMemberAction(
    `role-${member.userId}`,
    async () => {
      await changeGroupMemberRole(
        props.group?.id ?? 0,
        member.userId,
        next
      );
      toast.success(
        t('groups.manage.feedback.memberUpdated')
      );
    }
  );
}

function formatDate(value: string | null): string {
  if (!value) return t('groups.manage.never');
  return new Date(value).toLocaleString(
    locale.value === 'zh' ? 'zh-CN' : 'en-US',
    {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    }
  );
}

function statusLabel(status: string): string {
  const keys: Record<string, string> = {
    active: 'groups.manage.status.active',
    pending: 'groups.manage.status.pending',
    muted: 'groups.manage.status.muted',
    banned: 'groups.manage.status.banned'
  };
  return t(keys[status] ?? 'groups.manage.status.unknown');
}

function statusBadgeVariant(
  status: string
): 'default' | 'secondary' | 'destructive' | 'outline' {
  if (status === 'active') return 'secondary';
  if (status === 'pending') return 'outline';
  if (status === 'muted' || status === 'banned') {
    return 'destructive';
  }
  return 'outline';
}

function positiveInteger(
  value: unknown,
  fallback: number
): number {
  const next = Number(value);
  if (!Number.isFinite(next)) return fallback;
  return Math.max(Math.trunc(next), 1);
}

function muteActionLabel(member: GroupMember): string {
  return member.isMuted
    ? t('groups.member.actions.unmute')
    : t('groups.member.actions.mute');
}

function inviteUrl(invite: V2GroupInvite): string | null {
  if (!invite.invite_code) return null;
  const path = `/groups/invite/${invite.invite_code}`;
  if (typeof window === 'undefined') return path;
  return new URL(path, window.location.origin).toString();
}

async function copyText(value: string): Promise<void> {
  if (typeof navigator === 'undefined' || !navigator.clipboard) {
    return;
  }
  await navigator.clipboard.writeText(value);
}

async function saveSettings(): Promise<void> {
  if (!props.group) return;
  if (!form.name.trim()) {
    toast.error(t('groups.manage.validation.nameRequired'));
    return;
  }

  saving.value = true;
  try {
    const updated = await updateGroup(props.group.id, {
      ...form,
      name: form.name.trim(),
      description: form.description.trim(),
      avatar: form.avatar.trim(),
      coverImage: form.coverImage.trim()
    });
    emit('updated', updated);
    toast.success(t('groups.manage.feedback.updated'));
  } catch (error) {
    toast.error(t('groups.manage.feedback.updateFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    saving.value = false;
  }
}

async function runMemberAction(
  key: string,
  action: () => Promise<void>,
  refreshGroupAfter = false
): Promise<void> {
  if (!props.group || actionKey.value) return;
  actionKey.value = key;
  try {
    await action();
    await loadMembers();
    if (refreshGroupAfter) {
      await refreshGroup();
    }
  } catch (error) {
    toast.error(t('groups.manage.feedback.memberFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    actionKey.value = null;
  }
}

async function approveMember(
  member: GroupMember,
  approved: boolean
): Promise<void> {
  await runMemberAction(
    `${approved ? 'approve' : 'reject'}-${member.id}`,
    async () => {
      await approveGroupMember(
        props.group?.id ?? 0,
        member.id,
        approved
      );
      toast.success(
        approved
          ? t('groups.manage.feedback.memberApproved')
          : t('groups.manage.feedback.memberRejected')
      );
    },
    approved
  );
}

async function toggleMute(member: GroupMember): Promise<void> {
  await runMemberAction(
    `mute-${member.userId}`,
    async () => {
      if (member.isMuted) {
        await unmuteGroupMember(
          props.group?.id ?? 0,
          member.userId
        );
        toast.success(
          t('groups.member.feedback.unmuted')
        );
      } else {
        await muteGroupMember(
          props.group?.id ?? 0,
          member.userId,
          24,
          t('groups.manage.defaultMuteReason')
        );
        toast.success(t('groups.member.feedback.muted'));
      }
    }
  );
}

async function removeMember(
  member: GroupMember
): Promise<void> {
  await runMemberAction(
    `remove-${member.userId}`,
    async () => {
      await removeGroupMember(
        props.group?.id ?? 0,
        member.userId
      );
      toast.success(t('groups.member.feedback.removed'));
    },
    true
  );
}

async function transferOwnership(
  member: GroupMember
): Promise<void> {
  await runMemberAction(
    `transfer-${member.userId}`,
    async () => {
      await transferGroupOwnership(
        props.group?.id ?? 0,
        member.userId
      );
      toast.success(
        t('groups.manage.feedback.ownershipTransferred')
      );
    },
    true
  );
}

async function createInvite(): Promise<void> {
  if (!props.group || creatingInvite.value) return;
  creatingInvite.value = true;
  try {
    inviteMaxUses.value = positiveInteger(
      inviteMaxUses.value,
      100
    );
    inviteExpireHours.value = positiveInteger(
      inviteExpireHours.value,
      168
    );
    const invite = await createGroupInviteData(
      props.group.id,
      inviteMaxUses.value,
      inviteExpireHours.value
    );
    if (invite.invite_url) {
      const url =
        typeof window === 'undefined'
          ? invite.invite_url
          : new URL(
              invite.invite_url,
              window.location.origin
            ).toString();
      await copyText(url);
    }
    toast.success(t('groups.manage.feedback.inviteCreated'));
    await loadInvites();
  } catch (error) {
    toast.error(t('groups.feedback.inviteFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    creatingInvite.value = false;
  }
}

async function copyInvite(invite: V2GroupInvite): Promise<void> {
  const url = inviteUrl(invite);
  if (!url) return;
  await copyText(url);
  toast.success(t('groups.feedback.inviteCopied'));
}

async function deleteCurrentGroup(): Promise<void> {
  if (!props.group || deleteConfirm.value !== props.group.name) {
    toast.error(t('groups.manage.validation.deleteConfirm'));
    return;
  }
  deleting.value = true;
  try {
    await deleteGroup(props.group.id);
    toast.success(t('groups.manage.feedback.deleted'));
    emit('deleted', props.group.id);
    emit('update:open', false);
  } catch (error) {
    toast.error(t('groups.manage.feedback.deleteFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    deleting.value = false;
  }
}
</script>

<template>
  <Dialog
    :open="open"
    @update:open="emit('update:open', $event)"
  >
    <DialogContent class="max-w-5xl max-h-[92vh] p-0 overflow-hidden">
      <template v-if="group">
        <DialogHeader class="px-6 pt-6 pb-4">
          <div class="flex items-start justify-between gap-4">
            <div class="flex min-w-0 items-center gap-3">
              <Avatar class="h-12 w-12">
                <AvatarImage
                  :src="group.avatar"
                  :alt="group.name"
                />
                <AvatarFallback>
                  {{ group.name.slice(0, 1) }}
                </AvatarFallback>
              </Avatar>
              <div class="min-w-0">
                <DialogTitle class="truncate text-xl">
                  {{ t('groups.manage.title', { name: group.name }) }}
                </DialogTitle>
                <DialogDescription>
                  {{ t('groups.manage.description') }}
                </DialogDescription>
              </div>
            </div>
            <div class="hidden items-center gap-2 md:flex">
              <Badge variant="secondary">
                {{ t('groups.stats.membersCount', { count: activeMemberCount }) }}
              </Badge>
              <Badge variant="outline">
                {{ t(`groups.filters.privacy.${group.privacy}`) }}
              </Badge>
            </div>
          </div>
        </DialogHeader>

        <Separator />

        <Tabs v-model="activeTab" class="flex min-h-0 flex-col">
          <div class="px-6 pt-4">
            <TabsList class="grid w-full grid-cols-4">
              <TabsTrigger value="settings">
                {{ t('groups.manage.tabs.settings') }}
              </TabsTrigger>
              <TabsTrigger value="members">
                {{ t('groups.manage.tabs.members') }}
              </TabsTrigger>
              <TabsTrigger value="invites">
                {{ t('groups.manage.tabs.invites') }}
              </TabsTrigger>
              <TabsTrigger value="danger">
                {{ t('groups.manage.tabs.danger') }}
              </TabsTrigger>
            </TabsList>
          </div>

          <ScrollArea class="h-[62vh] px-6 py-5">
            <TabsContent value="settings" class="mt-0 space-y-5">
              <div class="grid gap-4 md:grid-cols-2">
                <div class="space-y-2">
                  <Label for="manage-group-name">
                    {{ t('groups.manage.fields.name') }}
                  </Label>
                  <Input
                    id="manage-group-name"
                    v-model="form.name"
                    maxlength="50"
                    :disabled="!canEditSettings"
                  />
                </div>
                <div class="space-y-2">
                  <Label>
                    {{ t('groups.manage.fields.privacy') }}
                  </Label>
                  <Select
                    :model-value="form.privacy"
                    :disabled="!canEditSettings"
                    @update:model-value="updatePrivacy"
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem
                        v-for="option in privacyOptions"
                        :key="option.value"
                        :value="option.value"
                      >
                        {{ t(option.labelKey) }}
                      </SelectItem>
                    </SelectContent>
                  </Select>
                </div>
              </div>

              <div class="space-y-2">
                <Label for="manage-group-description">
                  {{ t('groups.manage.fields.description') }}
                </Label>
                <Textarea
                  id="manage-group-description"
                  v-model="form.description"
                  maxlength="500"
                  class="min-h-24 resize-none"
                  :disabled="!canEditSettings"
                />
              </div>

              <div class="grid gap-4 md:grid-cols-2">
                <div class="space-y-2">
                  <Label for="manage-group-avatar">
                    {{ t('groups.manage.fields.avatar') }}
                  </Label>
                  <Input
                    id="manage-group-avatar"
                    v-model="form.avatar"
                    :disabled="!canEditSettings"
                  />
                </div>
                <div class="space-y-2">
                  <Label for="manage-group-cover">
                    {{ t('groups.manage.fields.cover') }}
                  </Label>
                  <Input
                    id="manage-group-cover"
                    v-model="form.coverImage"
                    :disabled="!canEditSettings"
                  />
                </div>
              </div>

              <div class="grid gap-4 md:grid-cols-2">
                <div
                  class="flex items-center justify-between rounded-lg border p-4"
                >
                  <div class="space-y-1">
                    <Label>
                      {{ t('groups.manage.fields.joinApproval') }}
                    </Label>
                    <p class="text-sm text-muted-foreground">
                      {{ t('groups.manage.fields.joinApprovalHint') }}
                    </p>
                  </div>
                  <Switch
                    :model-value="form.joinApproval"
                    :disabled="!canEditSettings"
                    @update:model-value="
                      form.joinApproval = Boolean($event)
                    "
                  />
                </div>

                <div class="space-y-2">
                  <Label>
                    {{ t('groups.manage.fields.postPermission') }}
                  </Label>
                  <Select
                    :model-value="form.postPermission"
                    :disabled="!canEditSettings"
                    @update:model-value="updatePostPermission"
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem
                        v-for="option in postPermissionOptions"
                        :key="option.value"
                        :value="option.value"
                      >
                        {{ t(option.labelKey) }}
                      </SelectItem>
                    </SelectContent>
                  </Select>
                </div>
              </div>
            </TabsContent>

            <TabsContent value="members" class="mt-0 space-y-5">
              <div
                v-if="pendingMembers.length > 0"
                class="space-y-3 rounded-lg border p-4"
              >
                <div class="flex items-center gap-2">
                  <Clock class="h-4 w-4 text-muted-foreground" />
                  <h3 class="font-medium">
                    {{ t('groups.manage.pendingTitle', { count: pendingMembers.length }) }}
                  </h3>
                </div>
                <div class="space-y-2">
                  <div
                    v-for="member in pendingMembers"
                    :key="member.id"
                    class="flex items-center justify-between gap-3 rounded-md border bg-muted/20 p-3"
                  >
                    <div class="flex min-w-0 items-center gap-3">
                      <Avatar class="h-9 w-9">
                        <AvatarImage
                          :src="member.avatar"
                          :alt="member.nickname"
                        />
                        <AvatarFallback>
                          {{ member.nickname.slice(0, 1) }}
                        </AvatarFallback>
                      </Avatar>
                      <div class="min-w-0">
                        <div class="truncate text-sm font-medium">
                          {{ member.nickname }}
                        </div>
                        <div class="truncate text-xs text-muted-foreground">
                          @{{ member.username }}
                        </div>
                      </div>
                    </div>
                    <div class="flex shrink-0 gap-2">
                      <Button
                        size="sm"
                        variant="outline"
                        :disabled="!canModerateMembers || !!actionKey"
                        @click="approveMember(member, false)"
                      >
                        <X class="mr-2 h-4 w-4" />
                        {{ t('groups.manage.actions.reject') }}
                      </Button>
                      <Button
                        size="sm"
                        :disabled="!canModerateMembers || !!actionKey"
                        @click="approveMember(member, true)"
                      >
                        <Check class="mr-2 h-4 w-4" />
                        {{ t('groups.manage.actions.approve') }}
                      </Button>
                    </div>
                  </div>
                </div>
              </div>

              <div class="flex items-center gap-2">
                <div class="relative flex-1">
                  <Search
                    class="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
                  />
                  <Input
                    v-model="memberSearch"
                    class="pl-9"
                    :placeholder="t('groups.manage.memberSearch')"
                  />
                </div>
                <Button
                  variant="outline"
                  :disabled="loadingMembers"
                  @click="loadMembers"
                >
                  <RefreshCw
                    :class="[
                      'mr-2 h-4 w-4',
                      { 'animate-spin': loadingMembers }
                    ]"
                  />
                  {{ t('common.refresh') }}
                </Button>
              </div>

              <div class="space-y-2">
                <div
                  v-for="member in managedMembers"
                  :key="member.id"
                  class="grid gap-3 rounded-lg border p-3 md:grid-cols-[minmax(0,1fr)_160px_auto]"
                >
                  <div class="flex min-w-0 items-center gap-3">
                    <Avatar class="h-10 w-10">
                      <AvatarImage
                        :src="member.avatar"
                        :alt="member.nickname"
                      />
                      <AvatarFallback>
                        {{ member.nickname.slice(0, 1) }}
                      </AvatarFallback>
                    </Avatar>
                    <div class="min-w-0">
                      <div class="flex items-center gap-2">
                        <span class="truncate text-sm font-medium">
                          {{ member.nickname }}
                        </span>
                        <Badge
                          :variant="statusBadgeVariant(member.status)"
                        >
                          {{ statusLabel(member.status) }}
                        </Badge>
                      </div>
                      <div class="truncate text-xs text-muted-foreground">
                        @{{ member.username }} · {{ t('groups.member.joinedAt', { date: formatDate(member.joinedAt) }) }}
                      </div>
                    </div>
                  </div>

                  <Select
                    :model-value="member.role"
                    :disabled="
                      !canEditSettings ||
                      member.role === 'owner' ||
                      !!actionKey
                    "
                    @update:model-value="
                      updateMemberRole(member, $event)
                    "
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem
                        v-if="member.role === 'owner'"
                        value="owner"
                        disabled
                      >
                        {{ t('groups.member.roles.owner') }}
                      </SelectItem>
                      <template v-else>
                        <SelectItem
                          v-for="option in roleOptions"
                          :key="option.value"
                          :value="option.value"
                        >
                          {{ t(option.labelKey) }}
                        </SelectItem>
                      </template>
                    </SelectContent>
                  </Select>

                  <TooltipProvider>
                    <div class="flex justify-end gap-2">
                      <Tooltip v-if="member.role !== 'owner'">
                        <TooltipTrigger as-child>
                          <Button
                            variant="outline"
                            size="icon"
                            :aria-label="muteActionLabel(member)"
                            :disabled="!canModerateMembers || !!actionKey"
                            @click="toggleMute(member)"
                          >
                            <component
                              :is="member.isMuted ? Volume2 : VolumeX"
                              class="h-4 w-4"
                            />
                          </Button>
                        </TooltipTrigger>
                        <TooltipContent>
                          {{ muteActionLabel(member) }}
                        </TooltipContent>
                      </Tooltip>
                      <Tooltip
                        v-if="
                          canTransferOwnership &&
                          member.role !== 'owner'
                        "
                      >
                        <TooltipTrigger as-child>
                          <Button
                            variant="outline"
                            size="icon"
                            :aria-label="
                              t('groups.manage.actions.transferOwnership')
                            "
                            :disabled="!!actionKey"
                            @click="transferOwnership(member)"
                          >
                            <Crown class="h-4 w-4" />
                          </Button>
                        </TooltipTrigger>
                        <TooltipContent>
                          {{ t('groups.manage.actions.transferOwnership') }}
                        </TooltipContent>
                      </Tooltip>
                      <Tooltip v-if="member.role !== 'owner'">
                        <TooltipTrigger as-child>
                          <Button
                            variant="outline"
                            size="icon"
                            class="text-destructive hover:text-destructive"
                            :aria-label="t('groups.member.actions.remove')"
                            :disabled="!canModerateMembers || !!actionKey"
                            @click="removeMember(member)"
                          >
                            <UserMinus class="h-4 w-4" />
                          </Button>
                        </TooltipTrigger>
                        <TooltipContent>
                          {{ t('groups.member.actions.remove') }}
                        </TooltipContent>
                      </Tooltip>
                    </div>
                  </TooltipProvider>
                </div>

                <div
                  v-if="!loadingMembers && managedMembers.length === 0"
                  class="rounded-lg border border-dashed p-8 text-center text-sm text-muted-foreground"
                >
                  {{ t('groups.manage.emptyMembers') }}
                </div>
              </div>
            </TabsContent>

            <TabsContent value="invites" class="mt-0 space-y-5">
              <div class="grid gap-4 rounded-lg border p-4 md:grid-cols-[1fr_1fr_auto]">
                <div class="space-y-2">
                  <Label for="invite-max-uses">
                    {{ t('groups.manage.invites.maxUses') }}
                  </Label>
                  <Input
                    id="invite-max-uses"
                    v-model.number="inviteMaxUses"
                    type="number"
                    min="1"
                  />
                </div>
                <div class="space-y-2">
                  <Label for="invite-expire-hours">
                    {{ t('groups.manage.invites.expireHours') }}
                  </Label>
                  <Input
                    id="invite-expire-hours"
                    v-model.number="inviteExpireHours"
                    type="number"
                    min="1"
                  />
                </div>
                <div class="flex items-end">
                  <Button
                    class="w-full"
                    :disabled="
                      !canModerateMembers || creatingInvite
                    "
                    @click="createInvite"
                  >
                    <Link class="mr-2 h-4 w-4" />
                    {{ t('groups.manage.invites.create') }}
                  </Button>
                </div>
              </div>

              <div class="space-y-2">
                <div
                  v-for="invite in invites"
                  :key="invite.invite_id"
                  class="grid gap-3 rounded-lg border p-3 md:grid-cols-[minmax(0,1fr)_120px_120px_auto]"
                >
                  <div class="min-w-0">
                    <div class="flex items-center gap-2">
                      <span class="font-mono text-sm">
                        {{ invite.invite_code || '-' }}
                      </span>
                      <Badge
                        :variant="
                          invite.is_valid ? 'secondary' : 'outline'
                        "
                      >
                        {{ invite.status }}
                      </Badge>
                    </div>
                    <p class="truncate text-xs text-muted-foreground">
                      {{ t('groups.manage.invites.expiresAt', { date: formatDate(invite.expires_at) }) }}
                    </p>
                  </div>
                  <div class="text-sm text-muted-foreground">
                    {{ invite.used_count }} / {{ invite.max_uses ?? '-' }}
                  </div>
                  <div class="text-sm text-muted-foreground">
                    {{ invite.inviter.display_name || invite.inviter.username }}
                  </div>
                  <TooltipProvider>
                    <Tooltip>
                      <TooltipTrigger as-child>
                        <Button
                          variant="outline"
                          size="icon"
                          :aria-label="
                            t('groups.manage.actions.copyInvite')
                          "
                          :disabled="!invite.invite_code"
                          @click="copyInvite(invite)"
                        >
                          <Copy class="h-4 w-4" />
                        </Button>
                      </TooltipTrigger>
                      <TooltipContent>
                        {{ t('groups.manage.actions.copyInvite') }}
                      </TooltipContent>
                    </Tooltip>
                  </TooltipProvider>
                </div>

                <div
                  v-if="!loadingInvites && invites.length === 0"
                  class="rounded-lg border border-dashed p-8 text-center text-sm text-muted-foreground"
                >
                  {{ t('groups.manage.invites.empty') }}
                </div>
              </div>
            </TabsContent>

            <TabsContent value="danger" class="mt-0 space-y-4">
              <div class="rounded-lg border border-destructive/30 p-4">
                <div class="flex items-start gap-3">
                  <div class="rounded-md bg-destructive/10 p-2 text-destructive">
                    <Trash2 class="h-5 w-5" />
                  </div>
                  <div class="space-y-2">
                    <h3 class="font-medium">
                      {{ t('groups.manage.danger.title') }}
                    </h3>
                    <p class="text-sm text-muted-foreground">
                      {{ t('groups.manage.danger.description') }}
                    </p>
                  </div>
                </div>
                <div class="mt-4 space-y-3">
                  <Label for="delete-confirm">
                    {{ t('groups.manage.danger.confirmLabel', { name: group.name }) }}
                  </Label>
                  <Input
                    id="delete-confirm"
                    v-model="deleteConfirm"
                    :disabled="!group.isOwner"
                    :placeholder="group.name"
                  />
                  <Button
                    variant="destructive"
                    :disabled="
                      !group.isOwner ||
                      deleting ||
                      deleteConfirm !== group.name
                    "
                    @click="deleteCurrentGroup"
                  >
                    <Trash2 class="mr-2 h-4 w-4" />
                    {{ t('groups.manage.danger.delete') }}
                  </Button>
                </div>
              </div>
            </TabsContent>
          </ScrollArea>
        </Tabs>

        <Separator />

        <DialogFooter class="px-6 py-4">
          <Button
            variant="outline"
            @click="emit('update:open', false)"
          >
            {{ t('common.close') }}
          </Button>
          <Button
            v-if="activeTab === 'settings'"
            :disabled="!canEditSettings || saving"
            @click="saveSettings"
          >
            <Save class="mr-2 h-4 w-4" />
            {{
              saving
                ? t('groups.manage.saving')
                : t('groups.manage.save')
            }}
          </Button>
        </DialogFooter>
      </template>
    </DialogContent>
  </Dialog>
</template>
