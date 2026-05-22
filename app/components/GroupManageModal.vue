<script setup lang="ts">
import {
  computed,
  onBeforeUnmount,
  reactive,
  ref,
  shallowRef,
  watch
} from 'vue';
import {
  AlertTriangle,
  Camera,
  Check,
  Clock,
  Copy,
  Crown,
  ImagePlus,
  Link,
  Loader2,
  RefreshCw,
  Save,
  Search,
  Settings,
  Trash2,
  UserMinus,
  Users,
  Volume2,
  VolumeX,
  X
} from 'lucide-vue-next';
import {
  Dialog,
  DialogContent,
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
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Switch } from '@/components/ui/switch';
import { Textarea } from '@/components/ui/textarea';
import { toast } from 'vue-sonner';
import GroupAvatarCropDialog from './GroupAvatarCropDialog.vue';
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
import { v2UploadMedia } from '@/services';
import type {
  Group,
  GroupCategory,
  GroupMember,
  GroupPrivacy,
  GroupRole,
  UpdateGroupData
} from '@/types/groups';
import type {
  V2GroupInvite,
  V2GroupPostPermission
} from '@/types/v2';
import { normalizeAssetUrl } from '@/utils/assets';

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
const avatarInputRef = ref<HTMLInputElement | null>(null);
const coverInputRef = ref<HTMLInputElement | null>(null);
const uploadingAvatar = ref(false);
const uploadingCover = ref(false);
const avatarCropDialogOpen = ref(false);
const avatarCropSourceUrl = ref<string | null>(null);
const avatarCropFileName = ref('avatar.jpg');

const form = reactive<UpdateGroupData>({
  name: '',
  description: '',
  avatar: '',
  coverImage: '',
  privacy: 'public',
  joinApproval: false,
  postPermission: 'all',
  category: null,
  tags: []
});
const tagsText = ref('');

const privacyOptions: Array<{
  value: GroupPrivacy;
  labelKey: string;
}> = [
  { value: 'public', labelKey: 'groups.filters.privacy.public' },
  { value: 'private', labelKey: 'groups.filters.privacy.private' },
  { value: 'secret', labelKey: 'groups.filters.privacy.secret' }
];

const categoryOptions = [
  { value: 'tech' as const, labelKey: 'groups.filters.category.tech' },
  { value: 'game' as const, labelKey: 'groups.filters.category.game' },
  { value: 'music' as const, labelKey: 'groups.filters.category.music' },
  { value: 'art' as const, labelKey: 'groups.filters.category.art' },
  { value: 'life' as const, labelKey: 'groups.filters.category.life' },
  { value: 'study' as const, labelKey: 'groups.filters.category.study' },
  { value: 'work' as const, labelKey: 'groups.filters.category.work' },
  { value: 'other' as const, labelKey: 'groups.filters.category.other' }
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

const PILL_BASE =
  'inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium';

const privacyPillClassMap: Record<GroupPrivacy, string> = {
  public:
    'border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300',
  private:
    'border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300',
  secret:
    'border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300'
};

function privacyPillClass(privacy: GroupPrivacy): string {
  return `${PILL_BASE} ${privacyPillClassMap[privacy]}`;
}

function statusPillClass(status: string): string {
  if (status === 'active') {
    return `${PILL_BASE} border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300`;
  }
  if (status === 'pending') {
    return `${PILL_BASE} border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300`;
  }
  if (status === 'muted' || status === 'banned') {
    return `${PILL_BASE} border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300`;
  }
  return `${PILL_BASE} border-border/60 bg-muted/40 text-muted-foreground`;
}

function invitePillClass(isValid: boolean): string {
  return isValid
    ? `${PILL_BASE} border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300`
    : `${PILL_BASE} border-border/60 bg-muted/40 text-muted-foreground`;
}

function resetForm(group: Group): void {
  form.name = group.name;
  form.description = group.description;
  form.avatar = group.avatar;
  form.coverImage = group.coverImage ?? '';
  form.privacy = group.privacy;
  form.joinApproval = group.joinApproval;
  form.postPermission = group.postPermission;
  form.category = group.category ?? null;
  form.tags = group.tags ?? [];
  tagsText.value = (group.tags ?? []).join(', ');
  deleteConfirm.value = '';
  memberSearch.value = '';
  uploadingAvatar.value = false;
  uploadingCover.value = false;
  resetAvatarInput();
  resetCoverInput();
  closeAvatarCropDialog();
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

function updateCategory(value: unknown): void {
  const next = String(value);
  if (
    next === 'tech' ||
    next === 'game' ||
    next === 'music' ||
    next === 'art' ||
    next === 'life' ||
    next === 'study' ||
    next === 'work' ||
    next === 'other'
  ) {
    form.category = next as GroupCategory;
  }
}

function normalizeTags(value: string): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const raw of value.split(/[,，\s]+/)) {
    const tag = raw.replace(/^#/, '').trim().slice(0, 50);
    const key = tag.toLowerCase();
    if (!tag || seen.has(key)) continue;
    seen.add(key);
    result.push(tag);
    if (result.length >= 8) break;
  }
  return result;
}

function resetAvatarInput(): void {
  if (avatarInputRef.value) {
    avatarInputRef.value.value = '';
  }
}

function resetCoverInput(): void {
  if (coverInputRef.value) {
    coverInputRef.value.value = '';
  }
}

function triggerAvatarUpload(): void {
  if (
    !canEditSettings.value ||
    uploadingAvatar.value ||
    avatarCropDialogOpen.value
  ) {
    return;
  }
  avatarInputRef.value?.click();
}

function triggerCoverUpload(): void {
  if (!canEditSettings.value || uploadingCover.value) return;
  coverInputRef.value?.click();
}

function clearAvatar(): void {
  if (!canEditSettings.value || uploadingAvatar.value) return;
  form.avatar = '';
  resetAvatarInput();
}

function clearCover(): void {
  if (!canEditSettings.value || uploadingCover.value) return;
  form.coverImage = '';
  resetCoverInput();
}

function isValidImageFile(file: File, maxSizeInMB: number): boolean {
  if (!file.type.startsWith('image/')) {
    toast.error(t('avatar.validation.imageOnly'));
    return false;
  }

  if (file.size > maxSizeInMB * 1024 * 1024) {
    toast.error(
      t('avatar.validation.maxSize', { size: maxSizeInMB })
    );
    return false;
  }

  return true;
}

async function uploadGroupImage(
  file: File,
  altText: string
): Promise<string> {
  const body = new FormData();
  body.append('file', file);
  body.append('alt_text', altText || file.name);
  const media = await v2UploadMedia(body);
  return normalizeAssetUrl(media.public_url);
}

function revokeObjectUrl(url: string | null): void {
  if (url) {
    URL.revokeObjectURL(url);
  }
}

function closeAvatarCropDialog(): void {
  avatarCropDialogOpen.value = false;
  revokeObjectUrl(avatarCropSourceUrl.value);
  avatarCropSourceUrl.value = null;
}

function openAvatarCropDialog(file: File): void {
  closeAvatarCropDialog();
  avatarCropFileName.value = file.name || 'avatar.jpg';
  avatarCropSourceUrl.value = URL.createObjectURL(file);
  avatarCropDialogOpen.value = true;
}

async function handleAvatarSelected(event: Event): Promise<void> {
  const target = event.target as HTMLInputElement | null;
  const file = target?.files?.[0];
  resetAvatarInput();

  if (!file || !isValidImageFile(file, 5)) return;

  openAvatarCropDialog(file);
}

async function handleAvatarCropApply(file: File): Promise<void> {
  closeAvatarCropDialog();
  uploadingAvatar.value = true;
  try {
    form.avatar = await uploadGroupImage(
      file,
      form.name || props.group?.name || file.name
    );
  } catch (error) {
    toast.error(t('avatar.feedback.uploadFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    uploadingAvatar.value = false;
  }
}

async function handleCoverSelected(event: Event): Promise<void> {
  const target = event.target as HTMLInputElement | null;
  const file = target?.files?.[0];
  resetCoverInput();

  if (!file || !isValidImageFile(file, 8)) return;

  uploadingCover.value = true;
  try {
    form.coverImage = await uploadGroupImage(
      file,
      form.name || props.group?.name || file.name
    );
  } catch (error) {
    toast.error(t('avatar.feedback.uploadFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    uploadingCover.value = false;
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
      coverImage: form.coverImage.trim(),
      category: form.category,
      tags: normalizeTags(tagsText.value)
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

onBeforeUnmount(() => {
  closeAvatarCropDialog();
});
</script>

<template>
  <Dialog
    :open="open"
    @update:open="emit('update:open', $event)"
  >
    <DialogContent
      class="flex max-h-[calc(100dvh-1rem)] max-w-5xl flex-col overflow-hidden rounded-xl border-border/60 p-0"
    >
      <template v-if="group">
        <DialogHeader
          class="border-b border-border/60 bg-background/60 px-5 py-4 backdrop-blur"
        >
          <div class="flex items-start justify-between gap-4">
            <div class="flex min-w-0 items-center gap-3">
              <Avatar class="h-12 w-12 ring-1 ring-border">
                <AvatarImage
                  :src="group.avatar"
                  :alt="group.name"
                />
                <AvatarFallback
                  class="bg-primary/10 text-base font-semibold text-primary"
                >
                  {{ group.name.slice(0, 1) }}
                </AvatarFallback>
              </Avatar>
              <div class="min-w-0 grid gap-1">
                <DialogTitle
                  class="truncate text-base font-semibold tracking-tight"
                >
                  {{ t('groups.manage.title', { name: group.name }) }}
                </DialogTitle>
                <p class="truncate text-xs text-muted-foreground">
                  {{ t('groups.manage.description') }}
                </p>
              </div>
            </div>
            <div class="hidden items-center gap-1.5 md:flex">
              <span
                class="inline-flex items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 text-[11px] font-medium text-muted-foreground"
              >
                <Users class="h-3 w-3" />
                {{ t('groups.stats.membersCount', { count: activeMemberCount }) }}
              </span>
              <span :class="privacyPillClass(group.privacy)">
                {{ t(`groups.filters.privacy.${group.privacy}`) }}
              </span>
            </div>
          </div>
        </DialogHeader>

        <Tabs
          v-model="activeTab"
          class="flex min-h-0 flex-1 flex-col"
        >
          <div class="overflow-x-auto border-b border-border/60 px-4 pt-4 pb-3 sm:px-5">
            <TabsList
              class="grid w-max min-w-full grid-cols-4 shadow-xs sm:w-full"
            >
              <TabsTrigger value="settings" class="text-xs font-medium">
                {{ t('groups.manage.tabs.settings') }}
              </TabsTrigger>
              <TabsTrigger value="members" class="text-xs font-medium">
                {{ t('groups.manage.tabs.members') }}
              </TabsTrigger>
              <TabsTrigger value="invites" class="text-xs font-medium">
                {{ t('groups.manage.tabs.invites') }}
              </TabsTrigger>
              <TabsTrigger value="danger" class="text-xs font-medium">
                {{ t('groups.manage.tabs.danger') }}
              </TabsTrigger>
            </TabsList>
          </div>

          <ScrollArea class="flex-1 min-h-0">
            <div class="px-4 py-4 sm:px-5 sm:py-5">
              <TabsContent value="settings" class="mt-0 grid gap-5">
                <section
                  class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none"
                >
                  <div class="flex items-center gap-2">
                    <span
                      class="flex h-7 w-7 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
                    >
                      <Settings class="h-4 w-4" />
                    </span>
                    <h3 class="text-sm font-semibold tracking-tight">
                      {{ t('groups.manage.tabs.settings') }}
                    </h3>
                  </div>

                  <div class="grid gap-4 md:grid-cols-2">
                    <div class="grid gap-1.5">
                      <Label
                        for="manage-group-name"
                        class="text-xs font-medium"
                      >
                        {{ t('groups.manage.fields.name') }}
                      </Label>
                      <Input
                        id="manage-group-name"
                        v-model="form.name"
                        maxlength="50"
                        class="h-9 shadow-xs"
                        :disabled="!canEditSettings"
                      />
                    </div>
                    <div class="grid gap-1.5">
                      <Label class="text-xs font-medium">
                        {{ t('groups.manage.fields.privacy') }}
                      </Label>
                      <Select
                        :model-value="form.privacy"
                        :disabled="!canEditSettings"
                        @update:model-value="updatePrivacy"
                      >
                        <SelectTrigger class="h-9 shadow-xs">
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

                  <div class="grid gap-1.5">
                    <Label
                      for="manage-group-description"
                      class="text-xs font-medium"
                    >
                      {{ t('groups.manage.fields.description') }}
                    </Label>
                    <Textarea
                      id="manage-group-description"
                      v-model="form.description"
                      maxlength="500"
                      class="min-h-24 resize-none shadow-xs"
                      :disabled="!canEditSettings"
                    />
                  </div>

                  <div class="grid gap-4 md:grid-cols-2">
                    <div class="grid gap-1.5">
                      <Label class="text-xs font-medium">
                        {{ t('groups.manage.fields.category') }}
                      </Label>
                      <Select
                        :model-value="form.category ?? ''"
                        :disabled="!canEditSettings"
                        @update:model-value="updateCategory"
                      >
                        <SelectTrigger class="h-9 shadow-xs">
                          <SelectValue
                            :placeholder="t('groups.create.categoryPlaceholder')"
                          />
                        </SelectTrigger>
                        <SelectContent>
                          <SelectItem
                            v-for="option in categoryOptions"
                            :key="option.value"
                            :value="option.value"
                          >
                            {{ t(option.labelKey) }}
                          </SelectItem>
                        </SelectContent>
                      </Select>
                    </div>
                    <div class="grid gap-1.5">
                      <Label
                        for="manage-group-tags"
                        class="text-xs font-medium"
                      >
                        {{ t('groups.manage.fields.tags') }}
                      </Label>
                      <Input
                        id="manage-group-tags"
                        v-model="tagsText"
                        :placeholder="t('groups.create.tagsPlaceholder')"
                        maxlength="160"
                        class="h-9 shadow-xs"
                        :disabled="!canEditSettings"
                      />
                      <p class="text-[11px] text-muted-foreground">
                        {{ t('groups.create.tagsHint') }}
                      </p>
                    </div>
                  </div>
                </section>

                <section
                  class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none"
                >
                  <div class="flex items-center gap-2">
                    <span
                      class="flex h-7 w-7 items-center justify-center rounded-md bg-violet-500/10 text-violet-600 dark:text-violet-400"
                    >
                      <ImagePlus class="h-4 w-4" />
                    </span>
                    <h3 class="text-sm font-semibold tracking-tight">
                      {{ t('groups.manage.fields.cover') }}
                    </h3>
                  </div>

                  <div class="grid gap-4 md:grid-cols-[220px_minmax(0,1fr)]">
                    <div class="grid gap-2">
                      <Label
                        for="manage-group-avatar"
                        class="text-xs font-medium"
                      >
                        {{ t('groups.manage.fields.avatar') }}
                      </Label>
                      <input
                        ref="avatarInputRef"
                        type="file"
                        accept="image/png,image/jpeg,image/gif,image/webp"
                        class="hidden"
                        @change="handleAvatarSelected"
                      >
                      <div class="flex items-center gap-3">
                        <Avatar class="h-16 w-16 ring-1 ring-border">
                          <AvatarImage
                            v-if="form.avatar"
                            :src="form.avatar"
                          />
                          <AvatarFallback
                            class="bg-primary/10 text-base font-semibold text-primary"
                          >
                            {{ form.name.slice(0, 1) || '?' }}
                          </AvatarFallback>
                        </Avatar>
                        <div class="flex gap-2">
                          <button
                            type="button"
                            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md border border-border/60 bg-background text-muted-foreground transition hover:bg-muted hover:text-foreground disabled:opacity-50"
                            :disabled="
                              !canEditSettings || uploadingAvatar
                            "
                            :aria-label="
                              t('groups.manage.fields.avatar')
                            "
                            @click="triggerAvatarUpload"
                          >
                            <Loader2
                              v-if="uploadingAvatar"
                              class="h-3.5 w-3.5 animate-spin"
                            />
                            <Camera v-else class="h-3.5 w-3.5" />
                          </button>
                          <button
                            v-if="form.avatar"
                            type="button"
                            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md border border-border/60 bg-background text-muted-foreground transition hover:bg-muted hover:text-foreground disabled:opacity-50"
                            :disabled="
                              !canEditSettings || uploadingAvatar
                            "
                            :aria-label="t('common.cancel')"
                            @click="clearAvatar"
                          >
                            <X class="h-3.5 w-3.5" />
                          </button>
                        </div>
                      </div>
                      <Input
                        id="manage-group-avatar"
                        v-model="form.avatar"
                        class="h-9 shadow-xs"
                        :disabled="!canEditSettings"
                      />
                    </div>
                    <div class="grid gap-2">
                      <div class="flex items-center justify-between gap-3">
                        <Label
                          for="manage-group-cover"
                          class="text-xs font-medium"
                        >
                          {{ t('groups.manage.fields.cover') }}
                        </Label>
                        <div class="flex shrink-0 gap-2">
                          <input
                            ref="coverInputRef"
                            type="file"
                            accept="image/png,image/jpeg,image/gif,image/webp"
                            class="hidden"
                            @change="handleCoverSelected"
                          >
                          <button
                            type="button"
                            class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-border/60 bg-background text-muted-foreground transition hover:bg-muted hover:text-foreground disabled:opacity-50"
                            :disabled="
                              !canEditSettings || uploadingCover
                            "
                            :aria-label="
                              t('groups.manage.fields.cover')
                            "
                            @click="triggerCoverUpload"
                          >
                            <Loader2
                              v-if="uploadingCover"
                              class="h-3.5 w-3.5 animate-spin"
                            />
                            <ImagePlus v-else class="h-3.5 w-3.5" />
                          </button>
                          <button
                            v-if="form.coverImage"
                            type="button"
                            class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-border/60 bg-background text-muted-foreground transition hover:bg-muted hover:text-foreground disabled:opacity-50"
                            :disabled="
                              !canEditSettings || uploadingCover
                            "
                            :aria-label="t('common.cancel')"
                            @click="clearCover"
                          >
                            <X class="h-3.5 w-3.5" />
                          </button>
                        </div>
                      </div>
                      <div
                        class="relative h-32 overflow-hidden rounded-lg border border-border/60 bg-muted/40"
                      >
                        <img
                          v-if="form.coverImage"
                          :src="form.coverImage"
                          :alt="form.name"
                          class="h-full w-full object-cover"
                        >
                        <div
                          v-else
                          class="flex h-full items-center justify-center text-muted-foreground"
                        >
                          <ImagePlus class="h-6 w-6" />
                        </div>
                      </div>
                      <Input
                        id="manage-group-cover"
                        v-model="form.coverImage"
                        class="h-9 shadow-xs"
                        :disabled="!canEditSettings"
                      />
                    </div>
                  </div>
                </section>

                <section
                  class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none"
                >
                  <div class="flex items-center gap-2">
                    <span
                      class="flex h-7 w-7 items-center justify-center rounded-md bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
                    >
                      <Users class="h-4 w-4" />
                    </span>
                    <h3 class="text-sm font-semibold tracking-tight">
                      {{ t('groups.manage.fields.postPermission') }}
                    </h3>
                  </div>

                  <div class="grid gap-4 md:grid-cols-2">
                    <div
                      class="flex items-center justify-between gap-3 rounded-lg border border-border/60 bg-muted/20 p-3"
                    >
                      <div class="min-w-0 grid gap-0.5">
                        <Label class="text-xs font-medium">
                          {{ t('groups.manage.fields.joinApproval') }}
                        </Label>
                        <p class="text-[11px] text-muted-foreground">
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

                    <div class="grid gap-1.5">
                      <Label class="text-xs font-medium">
                        {{ t('groups.manage.fields.postPermission') }}
                      </Label>
                      <Select
                        :model-value="form.postPermission"
                        :disabled="!canEditSettings"
                        @update:model-value="updatePostPermission"
                      >
                        <SelectTrigger class="h-9 shadow-xs">
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
                </section>
              </TabsContent>

              <TabsContent value="members" class="mt-0 grid gap-5">
                <section
                  v-if="pendingMembers.length > 0"
                  class="grid gap-3 rounded-xl border border-amber-500/30 bg-amber-50/40 p-4 dark:bg-amber-950/20"
                >
                  <div class="flex items-center gap-2">
                    <span
                      class="flex h-7 w-7 items-center justify-center rounded-md bg-amber-500/10 text-amber-600 dark:text-amber-400"
                    >
                      <Clock class="h-4 w-4" />
                    </span>
                    <h3 class="text-sm font-semibold tracking-tight">
                      {{ t('groups.manage.pendingTitle', { count: pendingMembers.length }) }}
                    </h3>
                  </div>
                  <div class="grid gap-2">
                    <div
                      v-for="member in pendingMembers"
                      :key="member.id"
                      class="flex flex-col gap-3 rounded-lg border border-border/60 bg-card p-3 shadow-xs sm:flex-row sm:items-center sm:justify-between"
                    >
                      <div class="flex min-w-0 items-center gap-3">
                        <Avatar class="h-9 w-9 ring-1 ring-border">
                          <AvatarImage
                            :src="member.avatar"
                            :alt="member.nickname"
                          />
                          <AvatarFallback
                            class="bg-primary/10 text-xs font-semibold text-primary"
                          >
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
                      <div
                        class="grid w-full grid-cols-2 gap-2 sm:w-auto sm:flex sm:shrink-0"
                      >
                        <Button
                          variant="outline"
                          class="h-8 rounded-md shadow-xs"
                          :disabled="
                            !canModerateMembers || !!actionKey
                          "
                          @click="approveMember(member, false)"
                        >
                          <X class="h-3.5 w-3.5" />
                          {{ t('groups.manage.actions.reject') }}
                        </Button>
                        <Button
                          class="h-8 rounded-md shadow-xs"
                          :disabled="
                            !canModerateMembers || !!actionKey
                          "
                          @click="approveMember(member, true)"
                        >
                          <Check class="h-3.5 w-3.5" />
                          {{ t('groups.manage.actions.approve') }}
                        </Button>
                      </div>
                    </div>
                  </div>
                </section>

                <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
                  <div class="relative min-w-0 sm:flex-1">
                    <Search
                      class="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
                    />
                    <Input
                      v-model="memberSearch"
                      class="h-9 pl-9 shadow-xs"
                      :placeholder="t('groups.manage.memberSearch')"
                    />
                  </div>
                  <Button
                    variant="outline"
                    class="h-9 w-full rounded-md shadow-xs sm:w-auto"
                    :disabled="loadingMembers"
                    @click="loadMembers"
                  >
                    <RefreshCw
                      :class="[
                        'h-3.5 w-3.5',
                        { 'animate-spin': loadingMembers }
                      ]"
                    />
                    {{ t('common.refresh') }}
                  </Button>
                </div>

                <div class="grid gap-2">
                  <div
                    v-for="member in managedMembers"
                    :key="member.id"
                    class="grid gap-3 rounded-lg border border-border/60 bg-card p-3 shadow-xs transition-shadow hover:shadow-sm md:grid-cols-[minmax(0,1fr)_160px_auto]"
                  >
                    <div class="flex min-w-0 items-center gap-3">
                      <Avatar class="h-10 w-10 ring-1 ring-border">
                        <AvatarImage
                          :src="member.avatar"
                          :alt="member.nickname"
                        />
                        <AvatarFallback
                          class="bg-primary/10 text-xs font-semibold text-primary"
                        >
                          {{ member.nickname.slice(0, 1) }}
                        </AvatarFallback>
                      </Avatar>
                      <div class="min-w-0">
                        <div class="flex items-center gap-2">
                          <span class="truncate text-sm font-medium">
                            {{ member.nickname }}
                          </span>
                          <span :class="statusPillClass(member.status)">
                            {{ statusLabel(member.status) }}
                          </span>
                        </div>
                        <div class="truncate text-xs text-muted-foreground">
                          @{{ member.username }} ·
                          {{ t('groups.member.joinedAt', { date: formatDate(member.joinedAt) }) }}
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
                      <SelectTrigger class="h-8 shadow-xs">
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

                    <div class="flex justify-end gap-1">
                      <button
                        v-if="member.role !== 'owner'"
                        type="button"
                        class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-muted-foreground transition hover:bg-muted hover:text-foreground disabled:opacity-50"
                        :aria-label="muteActionLabel(member)"
                        :title="muteActionLabel(member)"
                        :disabled="!canModerateMembers || !!actionKey"
                        @click="toggleMute(member)"
                      >
                        <component
                          :is="member.isMuted ? Volume2 : VolumeX"
                          class="h-3.5 w-3.5"
                        />
                      </button>
                      <button
                        v-if="
                          canTransferOwnership &&
                          member.role !== 'owner'
                        "
                        type="button"
                        class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-amber-500 transition hover:bg-amber-500/10 hover:text-amber-600 disabled:opacity-50"
                        :aria-label="
                          t('groups.manage.actions.transferOwnership')
                        "
                        :title="
                          t('groups.manage.actions.transferOwnership')
                        "
                        :disabled="!!actionKey"
                        @click="transferOwnership(member)"
                      >
                        <Crown class="h-3.5 w-3.5" />
                      </button>
                      <button
                        v-if="member.role !== 'owner'"
                        type="button"
                        class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-rose-500 transition hover:bg-rose-500/10 hover:text-rose-600 disabled:opacity-50"
                        :aria-label="t('groups.member.actions.remove')"
                        :title="t('groups.member.actions.remove')"
                        :disabled="!canModerateMembers || !!actionKey"
                        @click="removeMember(member)"
                      >
                        <UserMinus class="h-3.5 w-3.5" />
                      </button>
                    </div>
                  </div>

                  <div
                    v-if="!loadingMembers && managedMembers.length === 0"
                    class="flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-border/60 bg-muted/10 py-10 text-sm text-muted-foreground"
                  >
                    <span
                      class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
                    >
                      <Users class="h-5 w-5" />
                    </span>
                    {{ t('groups.manage.emptyMembers') }}
                  </div>
                </div>
              </TabsContent>

              <TabsContent value="invites" class="mt-0 grid gap-5">
                <section
                  class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none"
                >
                  <div class="flex items-center gap-2">
                    <span
                      class="flex h-7 w-7 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
                    >
                      <Link class="h-4 w-4" />
                    </span>
                    <h3 class="text-sm font-semibold tracking-tight">
                      {{ t('groups.manage.invites.create') }}
                    </h3>
                  </div>
                  <div class="grid gap-3 md:grid-cols-[1fr_1fr_auto] md:items-end">
                    <div class="grid gap-1.5">
                      <Label
                        for="invite-max-uses"
                        class="text-xs font-medium"
                      >
                        {{ t('groups.manage.invites.maxUses') }}
                      </Label>
                      <Input
                        id="invite-max-uses"
                        v-model.number="inviteMaxUses"
                        type="number"
                        min="1"
                        class="h-9 shadow-xs tabular-nums"
                      />
                    </div>
                    <div class="grid gap-1.5">
                      <Label
                        for="invite-expire-hours"
                        class="text-xs font-medium"
                      >
                        {{ t('groups.manage.invites.expireHours') }}
                      </Label>
                      <Input
                        id="invite-expire-hours"
                        v-model.number="inviteExpireHours"
                        type="number"
                        min="1"
                        class="h-9 shadow-xs tabular-nums"
                      />
                    </div>
                    <Button
                      class="h-9 w-full rounded-md shadow-xs md:w-auto"
                      :disabled="
                        !canModerateMembers || creatingInvite
                      "
                      @click="createInvite"
                    >
                      <Loader2
                        v-if="creatingInvite"
                        class="h-3.5 w-3.5 animate-spin"
                      />
                      <Link v-else class="h-3.5 w-3.5" />
                      {{ t('groups.manage.invites.create') }}
                    </Button>
                  </div>
                </section>

                <div class="grid gap-2">
                  <div
                    v-for="invite in invites"
                    :key="invite.invite_id"
                    class="grid gap-3 rounded-lg border border-border/60 bg-card p-3 shadow-xs transition-shadow hover:shadow-sm md:grid-cols-[minmax(0,1fr)_120px_140px_auto] md:items-center"
                  >
                    <div class="min-w-0 grid gap-1">
                      <div class="flex min-w-0 flex-wrap items-center gap-2">
                        <span
                          class="break-all rounded-md bg-muted/40 px-2 py-0.5 font-mono text-xs"
                        >
                          {{ invite.invite_code || '-' }}
                        </span>
                        <span :class="invitePillClass(invite.is_valid)">
                          {{ invite.status }}
                        </span>
                      </div>
                      <p class="truncate text-[11px] text-muted-foreground">
                        {{ t('groups.manage.invites.expiresAt', { date: formatDate(invite.expires_at) }) }}
                      </p>
                    </div>
                    <div class="text-xs tabular-nums text-muted-foreground">
                      <span class="font-medium text-foreground">
                        {{ invite.used_count }}
                      </span>
                      / {{ invite.max_uses ?? '-' }}
                    </div>
                    <div class="truncate text-xs text-muted-foreground">
                      {{ invite.inviter.display_name || invite.inviter.username }}
                    </div>
                    <div class="flex justify-end">
                      <button
                        type="button"
                        class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-muted-foreground transition hover:bg-muted hover:text-foreground disabled:opacity-50"
                        :aria-label="
                          t('groups.manage.actions.copyInvite')
                        "
                        :title="
                          t('groups.manage.actions.copyInvite')
                        "
                        :disabled="!invite.invite_code"
                        @click="copyInvite(invite)"
                      >
                        <Copy class="h-3.5 w-3.5" />
                      </button>
                    </div>
                  </div>

                  <div
                    v-if="!loadingInvites && invites.length === 0"
                    class="flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-border/60 bg-muted/10 py-10 text-sm text-muted-foreground"
                  >
                    <span
                      class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
                    >
                      <Link class="h-5 w-5" />
                    </span>
                    {{ t('groups.manage.invites.empty') }}
                  </div>
                </div>
              </TabsContent>

              <TabsContent value="danger" class="mt-0 grid gap-4">
                <section
                  class="grid gap-4 rounded-xl border border-rose-500/30 bg-rose-50/40 p-5 shadow-none dark:bg-rose-950/20"
                >
                  <div class="flex items-start gap-3">
                    <span
                      class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-rose-500/10 text-rose-600 dark:text-rose-400"
                    >
                      <AlertTriangle class="h-4 w-4" />
                    </span>
                    <div class="grid gap-1">
                      <h3 class="text-sm font-semibold tracking-tight">
                        {{ t('groups.manage.danger.title') }}
                      </h3>
                      <p class="text-xs text-muted-foreground">
                        {{ t('groups.manage.danger.description') }}
                      </p>
                    </div>
                  </div>
                  <div class="grid gap-2">
                    <Label
                      for="delete-confirm"
                      class="text-xs font-medium"
                    >
                      {{ t('groups.manage.danger.confirmLabel', { name: group.name }) }}
                    </Label>
                    <Input
                      id="delete-confirm"
                      v-model="deleteConfirm"
                      class="h-9 shadow-xs"
                      :disabled="!group.isOwner"
                      :placeholder="group.name"
                    />
                    <Button
                      variant="destructive"
                      class="h-9 rounded-md shadow-xs"
                      :disabled="
                        !group.isOwner ||
                        deleting ||
                        deleteConfirm !== group.name
                      "
                      @click="deleteCurrentGroup"
                    >
                      <Loader2
                        v-if="deleting"
                        class="h-3.5 w-3.5 animate-spin"
                      />
                      <Trash2 v-else class="h-3.5 w-3.5" />
                      {{ t('groups.manage.danger.delete') }}
                    </Button>
                  </div>
                </section>
              </TabsContent>
            </div>
          </ScrollArea>
        </Tabs>

        <DialogFooter
          class="flex flex-col-reverse gap-2 border-t border-border/60 bg-background/60 px-5 py-3 backdrop-blur sm:flex-row sm:justify-end"
        >
          <Button
            variant="outline"
            class="h-9 rounded-md shadow-xs"
            @click="emit('update:open', false)"
          >
            <X class="h-3.5 w-3.5" />
            {{ t('common.close') }}
          </Button>
          <Button
            v-if="activeTab === 'settings'"
            class="h-9 rounded-md shadow-xs"
            :disabled="
              !canEditSettings ||
              saving ||
              uploadingAvatar ||
              uploadingCover
            "
            @click="saveSettings"
          >
            <Loader2
              v-if="saving"
              class="h-3.5 w-3.5 animate-spin"
            />
            <Save v-else class="h-3.5 w-3.5" />
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

  <GroupAvatarCropDialog
    v-model:open="avatarCropDialogOpen"
    :source-url="avatarCropSourceUrl"
    :file-name="avatarCropFileName"
    :alt="form.name || group?.name || t('groups.manage.fields.avatar')"
    @update:open="
      value => {
        if (!value) closeAvatarCropDialog()
      }
    "
    @apply="handleAvatarCropApply"
  />
</template>
