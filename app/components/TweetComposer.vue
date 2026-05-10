<script setup lang="ts">
import {
  computed,
  nextTick,
  onBeforeUnmount,
  ref
} from 'vue';
import type { Component } from 'vue';
import type {
  CreatePostFormVM,
  PreviewPostVM
} from '@/types/posts';
import type { V2PostVisibility } from '@/types/v2';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Popover,
  PopoverContent,
  PopoverTrigger
} from '@/components/ui/popover';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import { Separator } from '@/components/ui/separator';
import { Textarea } from '@/components/ui/textarea';
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger
} from '@/components/ui/tooltip';
import {
  AtSign,
  Globe,
  Hash,
  ImageUp,
  Lock,
  MapPin,
  MessageSquareQuote,
  MessageSquareReply,
  PlayCircle,
  Plus,
  SmilePlus,
  Users,
  X
} from 'lucide-vue-next';
import AppSendButton from '@/components/app/AppSendButton.vue';
import { toast } from 'vue-sonner';
import TweetPreviewCard from './TweetPreviewCard.vue';
import MentionPicker from './MentionPicker.vue';

interface MediaDraft {
  id: string;
  file: File;
  previewUrl: string;
  kind: 'image' | 'video';
  altText: string;
}

interface MentionDraft {
  username: string;
  userId: number;
  displayName: string;
}

interface MentionItem {
  type: string;
  id: string;
  userId?: string;
  displayName: string;
}

const props = withDefaults(
  defineProps<{
    replyTo?: PreviewPostVM;
    quoteTo?: PreviewPostVM;
    isSubmitting?: boolean;
  }>(),
  {
    isSubmitting: false
  }
);

const emit = defineEmits<{
  (e: 'open-quote-dialog'): void;
  (e: 'open-reply-dialog'): void;
  (e: 'clear-reply'): void;
  (e: 'clear-quote'): void;
  (
    e: 'submit',
    form: CreatePostFormVM,
    formData: FormData
  ): void;
}>();

const { t } = useAppLocale();

const MAX_CHARS = 280;
const MAX_MEDIA = 4;
const MAX_TAGS = 8;
const MAX_LOCATION_LENGTH = 60;
const quickEmojis = [
  '🔥',
  '✨',
  '🚀',
  '💡',
  '👏',
  '❤️',
  '😄',
  '👀'
];

const visibilityOptions: Array<{
  value: V2PostVisibility;
  labelKey: string;
  icon: Component;
}> = [
  {
    value: 'public',
    labelKey: 'post.composer.visibility.public',
    icon: Globe
  },
  {
    value: 'followers',
    labelKey: 'post.composer.visibility.followers',
    icon: Users
  },
  {
    value: 'mentioned',
    labelKey: 'post.composer.visibility.mentioned',
    icon: AtSign
  },
  {
    value: 'private',
    labelKey: 'post.composer.visibility.private',
    icon: Lock
  }
];

const tweetContent = ref('');
const visibility = ref<V2PostVisibility>('public');
const location = ref('');
const tagInput = ref('');
const manualTags = ref<string[]>([]);
const mediaDrafts = ref<MediaDraft[]>([]);
const selectedMentions = ref<MentionDraft[]>([]);
const fileInputRef = ref<HTMLInputElement | null>(null);
const textareaEl = ref<HTMLTextAreaElement | null>(null);
const showMentionPicker = ref(false);
const mentionSearchQuery = ref('');
const mentionPickerPosition = ref({ top: 0, left: 0 });
const mentionStartIndex = ref(-1);
const mentionPickerRef =
  ref<InstanceType<typeof MentionPicker>>();
const isDraggingMedia = ref(false);

const characterCount = computed(
  () => tweetContent.value.length
);

const contentHasValue = computed(
  () => tweetContent.value.trim().length > 0
);

const parsedTags = computed(() =>
  Array.from(
    tweetContent.value.matchAll(/#([\p{L}\p{N}_]+)/gu)
  )
    .map(match => normalizeTagName(match[1] ?? ''))
    .filter(Boolean)
);

const tagNames = computed(() =>
  uniqueValues([...parsedTags.value, ...manualTags.value])
    .slice(0, MAX_TAGS)
);

const activeMentions = computed(() =>
  selectedMentions.value.filter(mention =>
    tweetContent.value.includes(`@${mention.username}`)
  )
);

const mentionUserIds = computed(() =>
  uniqueNumbers(activeMentions.value.map(item => item.userId))
);

const isTweetDisabled = computed(() => {
  if (props.isSubmitting) return true;
  if (characterCount.value > MAX_CHARS) return true;
  return !contentHasValue.value && mediaDrafts.value.length === 0;
});

const remainingCharacters = computed(
  () => MAX_CHARS - characterCount.value
);

const circumference = 2 * Math.PI * 14;

const progressOffset = computed(() => {
  const progress = Math.min(
    characterCount.value / MAX_CHARS,
    1
  );
  return circumference * (1 - progress);
});

const progressColorClass = computed(() => {
  if (characterCount.value > MAX_CHARS) {
    return 'text-destructive';
  }
  if (remainingCharacters.value <= 20) {
    return 'text-amber-500';
  }
  return 'text-primary';
});

const selectedVisibility = computed(
  () =>
    visibilityOptions.find(
      option => option.value === visibility.value
    ) ?? {
      value: 'public' as const,
      labelKey: 'post.composer.visibility.public',
      icon: Globe
    }
);

const contextPost = computed(() => props.replyTo ?? props.quoteTo);

const contextLabel = computed(() =>
  props.replyTo
    ? t('post.composer.replyingTo')
    : t('post.composer.quoting')
);

const mediaGridClass = computed(() => ({
  'grid-cols-1': mediaDrafts.value.length === 1,
  'grid-cols-2': mediaDrafts.value.length > 1
}));

function uniqueValues(values: string[]): string[] {
  return Array.from(new Set(values.filter(Boolean)));
}

function uniqueNumbers(values: number[]): number[] {
  return Array.from(
    new Set(
      values.filter(value => Number.isFinite(value) && value > 0)
    )
  );
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function normalizeTagName(value: string): string {
  return value
    .trim()
    .replace(/^#+/, '')
    .replace(/[^\p{L}\p{N}_]/gu, '')
    .slice(0, 32);
}

function formatFileSize(size: number): string {
  if (size < 1024 * 1024) {
    return `${Math.max(size / 1024, 1).toFixed(0)} KB`;
  }
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

function updateVisibility(value: unknown): void {
  if (
    value === 'public' ||
    value === 'followers' ||
    value === 'mentioned' ||
    value === 'private'
  ) {
    visibility.value = value;
  }
}

function triggerFileInput(): void {
  fileInputRef.value?.click();
}

function mediaKind(file: File): MediaDraft['kind'] | null {
  if (file.type.startsWith('image/')) return 'image';
  if (file.type.startsWith('video/')) return 'video';
  return null;
}

function appendMediaFiles(files: File[]): void {
  const availableSlots = MAX_MEDIA - mediaDrafts.value.length;
  if (availableSlots <= 0) {
    toast.error(t('post.composer.mediaLimitTitle'), {
      description: t('post.composer.mediaLimitDescription', {
        count: 0
      })
    });
    return;
  }

  const accepted: MediaDraft[] = [];
  const rejected = files.filter(file => !mediaKind(file));

  for (const file of files) {
    const kind = mediaKind(file);
    if (!kind || accepted.length >= availableSlots) continue;
    accepted.push({
      id: `${file.name}-${file.size}-${file.lastModified}-${crypto.randomUUID()}`,
      file,
      previewUrl: URL.createObjectURL(file),
      kind,
      altText: ''
    });
  }

  if (files.length > availableSlots) {
    toast.error(t('post.composer.mediaLimitTitle'), {
      description: t('post.composer.mediaLimitDescription', {
        count: availableSlots
      })
    });
  }

  if (rejected.length > 0) {
    toast.error(t('post.composer.mediaTypeTitle'), {
      description: t('post.composer.mediaTypeDescription')
    });
  }

  mediaDrafts.value = [...mediaDrafts.value, ...accepted];
}

function handleFileSelect(event: Event): void {
  const target = event.target as HTMLInputElement;
  appendMediaFiles(Array.from(target.files ?? []));
  target.value = '';
}

function handlePaste(event: ClipboardEvent): void {
  const files = Array.from(event.clipboardData?.files ?? []);
  if (files.length === 0) return;
  appendMediaFiles(files);
}

function handleDrop(event: DragEvent): void {
  event.preventDefault();
  isDraggingMedia.value = false;
  appendMediaFiles(Array.from(event.dataTransfer?.files ?? []));
}

function removeMedia(index: number): void {
  const removed = mediaDrafts.value[index];
  if (!removed) return;
  URL.revokeObjectURL(removed.previewUrl);
  mediaDrafts.value = mediaDrafts.value.filter(
    (_, itemIndex) => itemIndex !== index
  );
}

function addManualTag(): void {
  const tag = normalizeTagName(tagInput.value);
  if (!tag) return;

  if (tagNames.value.includes(tag)) {
    toast.info(t('post.composer.duplicateTag'));
    tagInput.value = '';
    return;
  }

  if (tagNames.value.length >= MAX_TAGS) {
    toast.error(t('post.composer.tagLimitTitle'), {
      description: t('post.composer.tagLimitDescription', {
        count: MAX_TAGS
      })
    });
    return;
  }

  manualTags.value = [...manualTags.value, tag];
  tagInput.value = '';
}

function removeManualTag(tag: string): void {
  manualTags.value = manualTags.value.filter(
    item => item !== tag
  );
}

function insertAtCursor(value: string): void {
  const textarea = textareaEl.value;
  const current = tweetContent.value;
  const start = textarea?.selectionStart ?? current.length;
  const end = textarea?.selectionEnd ?? current.length;
  tweetContent.value =
    current.slice(0, start) + value + current.slice(end);

  void nextTick(() => {
    const nextPosition = start + value.length;
    textarea?.setSelectionRange(nextPosition, nextPosition);
    textarea?.focus();
  });
}

function startMention(): void {
  insertAtCursor('@');
  void nextTick(() => {
    const textarea = textareaEl.value;
    if (!textarea) return;
    updateMentionPicker(
      tweetContent.value,
      textarea.selectionStart,
      textarea
    );
  });
}

function removeMention(username: string): void {
  const pattern = new RegExp(
    `@${escapeRegExp(username)}\\b\\s?`,
    'g'
  );
  tweetContent.value = tweetContent.value.replace(pattern, '');
  selectedMentions.value = selectedMentions.value.filter(
    item => item.username !== username
  );
}

function updateMentionPicker(
  content: string,
  cursorPos: number,
  textarea: HTMLTextAreaElement
): void {
  const textBeforeCursor = content.substring(0, cursorPos);
  const match = textBeforeCursor.match(
    /(^|\s)@([\p{L}\p{N}_-]*)$/u
  );

  if (!match) {
    showMentionPicker.value = false;
    return;
  }

  const query = match[2] ?? '';
  mentionStartIndex.value = cursorPos - query.length - 1;
  mentionSearchQuery.value = query;
  showMentionPicker.value = true;

  void nextTick(() => {
    const rect = textarea.getBoundingClientRect();
    mentionPickerPosition.value = {
      top: Math.min(rect.top + 72, window.innerHeight - 360),
      left: Math.min(rect.left + 12, window.innerWidth - 340)
    };
  });
}

function handleInput(event: Event): void {
  const textarea = event.target as HTMLTextAreaElement;
  textareaEl.value = textarea;
  updateMentionPicker(
    textarea.value,
    textarea.selectionStart,
    textarea
  );
}

function handleMentionSelect(item: MentionItem): void {
  if (
    !textareaEl.value ||
    mentionStartIndex.value < 0 ||
    item.type !== 'user'
  ) {
    return;
  }

  const textarea = textareaEl.value;
  const content = tweetContent.value;
  let endPos = mentionStartIndex.value + 1;

  while (
    endPos < content.length &&
    !/\s/u.test(content[endPos] ?? '')
  ) {
    endPos++;
  }

  const mentionText = `@${item.id}`;
  tweetContent.value =
    content.substring(0, mentionStartIndex.value) +
    mentionText +
    ' ' +
    content.substring(endPos);

  const userId = Number(item.userId);
  if (Number.isFinite(userId) && userId > 0) {
    const exists = selectedMentions.value.some(
      mention => mention.userId === userId
    );
    if (!exists) {
      selectedMentions.value = [
        ...selectedMentions.value,
        {
          username: item.id,
          userId,
          displayName: item.displayName
        }
      ];
    }
  }

  void nextTick(() => {
    const nextPosition =
      mentionStartIndex.value + mentionText.length + 1;
    textarea.setSelectionRange(nextPosition, nextPosition);
    textarea.focus();
  });

  showMentionPicker.value = false;
}

function handleKeyDown(event: KeyboardEvent): void {
  textareaEl.value = event.target as HTMLTextAreaElement;
  if (showMentionPicker.value && mentionPickerRef.value) {
    mentionPickerRef.value.handleKeyDown(event);
  }
}

function clearContext(): void {
  if (props.replyTo) emit('clear-reply');
  if (props.quoteTo) emit('clear-quote');
}

function buildMediaFormData(): FormData {
  const formData = new FormData();
  mediaDrafts.value.forEach((draft, index) => {
    formData.append('file', draft.file);
    formData.append(
      `altText:${index}`,
      draft.altText.trim()
    );
  });
  return formData;
}

function handleSubmit(): void {
  if (isTweetDisabled.value) return;

  const form: CreatePostFormVM = {
    content: tweetContent.value.trim(),
    visibility: visibility.value,
    mediaIds: [],
    tagNames: tagNames.value,
    mentionUserIds: mentionUserIds.value,
    replyToPostId: props.replyTo?.id ?? null,
    repostOfPostId: null,
    quotedPostId: props.quoteTo?.id ?? null,
    location: location.value.trim() || undefined
  };

  emit('submit', form, buildMediaFormData());
}

function reset(): void {
  tweetContent.value = '';
  visibility.value = 'public';
  location.value = '';
  tagInput.value = '';
  manualTags.value = [];
  selectedMentions.value = [];
  showMentionPicker.value = false;
  mediaDrafts.value.forEach(draft => {
    URL.revokeObjectURL(draft.previewUrl);
  });
  mediaDrafts.value = [];
}

onBeforeUnmount(() => {
  mediaDrafts.value.forEach(draft => {
    URL.revokeObjectURL(draft.previewUrl);
  });
});

defineExpose({
  reset
});
</script>

<template>
  <div
    class="overflow-hidden rounded-xl border bg-card text-card-foreground shadow-sm"
    @drop="handleDrop"
    @dragover.prevent="isDraggingMedia = true"
    @dragleave="isDraggingMedia = false"
  >
    <div class="space-y-4 p-4 sm:p-5">
      <div
        v-if="contextPost"
        class="relative rounded-lg border bg-muted/30 p-3"
      >
        <div class="mb-2 flex items-center justify-between gap-3">
          <Badge variant="secondary" class="gap-1">
            <component
              :is="replyTo ? MessageSquareReply : MessageSquareQuote"
              class="h-3.5 w-3.5"
            />
            {{ contextLabel }}
          </Badge>
          <Button
            variant="ghost"
            size="icon"
            class="h-7 w-7"
            :aria-label="t('post.composer.clearContext')"
            @click="clearContext"
          >
            <X class="h-4 w-4" />
          </Button>
        </div>
        <TweetPreviewCard :tweet="contextPost" />
      </div>

      <div
        class="relative rounded-lg border bg-background/60 transition-colors"
        :class="{
          'border-primary ring-2 ring-primary/20': isDraggingMedia
        }"
      >
        <Textarea
          v-model="tweetContent"
          :placeholder="t('post.composer.placeholder')"
          class="min-h-44 resize-none border-0 bg-transparent p-4 text-base shadow-none focus-visible:ring-0 md:text-base"
          @input="handleInput"
          @keydown="handleKeyDown"
          @paste="handlePaste"
        />
        <div
          class="pointer-events-none absolute inset-x-4 bottom-3 text-xs text-muted-foreground"
          :class="{ hidden: !isDraggingMedia }"
        >
          {{ t('post.composer.dropHint') }}
        </div>
      </div>

      <MentionPicker
        ref="mentionPickerRef"
        :show="showMentionPicker"
        :search-query="mentionSearchQuery"
        :position="mentionPickerPosition"
        @select="handleMentionSelect"
        @close="showMentionPicker = false"
      />

      <div
        v-if="mediaDrafts.length > 0"
        class="grid gap-3"
        :class="mediaGridClass"
      >
        <div
          v-for="(draft, index) in mediaDrafts"
          :key="draft.id"
          class="group overflow-hidden rounded-lg border bg-muted/20"
        >
          <div class="relative aspect-video bg-muted">
            <img
              v-if="draft.kind === 'image'"
              :src="draft.previewUrl"
              class="h-full w-full object-cover"
              :alt="t('post.composer.mediaPreviewAlt')"
            />
            <video
              v-else
              :src="draft.previewUrl"
              class="h-full w-full object-cover"
              muted
              playsinline
            />
            <div
              v-if="draft.kind === 'video'"
              class="absolute inset-0 flex items-center justify-center bg-black/20"
            >
              <PlayCircle class="h-10 w-10 text-white/90" />
            </div>
            <Button
              variant="secondary"
              size="icon"
              class="absolute right-2 top-2 h-8 w-8 rounded-full opacity-0 shadow-sm transition-opacity group-hover:opacity-100"
              :aria-label="t('post.composer.removeMedia')"
              @click="removeMedia(index)"
            >
              <X class="h-4 w-4" />
            </Button>
          </div>
          <div class="space-y-2 p-3">
            <div class="flex items-center justify-between gap-2">
              <span class="truncate text-xs text-muted-foreground">
                {{ draft.file.name }}
              </span>
              <span class="shrink-0 text-xs text-muted-foreground">
                {{ formatFileSize(draft.file.size) }}
              </span>
            </div>
            <Input
              v-model="draft.altText"
              :placeholder="t('post.composer.altTextPlaceholder')"
              maxlength="120"
              class="h-8 text-xs"
            />
          </div>
        </div>
      </div>

      <div
        v-if="
          tagNames.length > 0 ||
          activeMentions.length > 0 ||
          location.trim()
        "
        class="flex flex-wrap gap-2"
      >
        <Badge
          v-for="tag in tagNames"
          :key="`tag-${tag}`"
          variant="outline"
          class="gap-1"
        >
          <Hash class="h-3 w-3" />
          {{ tag }}
          <button
            v-if="manualTags.includes(tag)"
            type="button"
            class="ml-1 rounded-full text-muted-foreground hover:text-foreground"
            @click="removeManualTag(tag)"
          >
            <X class="h-3 w-3" />
          </button>
        </Badge>
        <Badge
          v-for="mention in activeMentions"
          :key="`mention-${mention.userId}`"
          variant="secondary"
          class="gap-1"
        >
          <AtSign class="h-3 w-3" />
          {{ mention.displayName }}
          <button
            type="button"
            class="ml-1 rounded-full text-muted-foreground hover:text-foreground"
            @click="removeMention(mention.username)"
          >
            <X class="h-3 w-3" />
          </button>
        </Badge>
        <Badge
          v-if="location.trim()"
          variant="outline"
          class="gap-1"
        >
          <MapPin class="h-3 w-3" />
          {{ location.trim() }}
          <button
            type="button"
            class="ml-1 rounded-full text-muted-foreground hover:text-foreground"
            @click="location = ''"
          >
            <X class="h-3 w-3" />
          </button>
        </Badge>
      </div>
    </div>

    <Separator />

    <div
      class="flex flex-col gap-3 p-3 sm:flex-row sm:items-center sm:justify-between"
    >
      <div class="flex flex-wrap items-center gap-1.5">
        <TooltipProvider>
          <Tooltip>
            <TooltipTrigger as-child>
              <Button
                variant="ghost"
                size="icon"
                :aria-label="t('post.composer.addMedia')"
                @click="triggerFileInput"
              >
                <ImageUp class="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>
              {{ t('post.composer.addMedia') }}
            </TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger as-child>
              <Button
                variant="ghost"
                size="icon"
                :aria-label="t('post.composer.replyPost')"
                @click="emit('open-reply-dialog')"
              >
                <MessageSquareReply class="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>
              {{ t('post.composer.replyPost') }}
            </TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger as-child>
              <Button
                variant="ghost"
                size="icon"
                :aria-label="t('post.composer.quotePost')"
                @click="emit('open-quote-dialog')"
              >
                <MessageSquareQuote class="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>
              {{ t('post.composer.quotePost') }}
            </TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger as-child>
              <Button
                variant="ghost"
                size="icon"
                :aria-label="t('post.composer.addMention')"
                @click="startMention"
              >
                <AtSign class="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>
              {{ t('post.composer.addMention') }}
            </TooltipContent>
          </Tooltip>
        </TooltipProvider>

        <Select
          :model-value="visibility"
          @update:model-value="updateVisibility"
        >
          <SelectTrigger class="h-9 w-[154px]">
            <component
              :is="selectedVisibility.icon"
              class="mr-2 h-4 w-4 text-muted-foreground"
            />
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem
              v-for="option in visibilityOptions"
              :key="option.value"
              :value="option.value"
            >
              {{ t(option.labelKey) }}
            </SelectItem>
          </SelectContent>
        </Select>

        <Popover>
          <PopoverTrigger as-child>
            <Button variant="outline" size="sm" class="gap-2">
              <Hash class="h-4 w-4" />
              {{ t('post.composer.addTag') }}
            </Button>
          </PopoverTrigger>
          <PopoverContent class="w-72" align="start">
            <div class="space-y-3">
              <Label for="post-tag-input">
                {{ t('post.composer.tagLabel') }}
              </Label>
              <div class="flex gap-2">
                <Input
                  id="post-tag-input"
                  v-model="tagInput"
                  :placeholder="t('post.composer.tagPlaceholder')"
                  maxlength="32"
                  @keydown.enter.prevent="addManualTag"
                />
                <Button
                  type="button"
                  size="icon"
                  @click="addManualTag"
                >
                  <Plus class="h-4 w-4" />
                </Button>
              </div>
            </div>
          </PopoverContent>
        </Popover>

        <Popover>
          <PopoverTrigger as-child>
            <Button variant="outline" size="sm" class="gap-2">
              <MapPin class="h-4 w-4" />
              {{ t('post.composer.addLocation') }}
            </Button>
          </PopoverTrigger>
          <PopoverContent class="w-80" align="start">
            <div class="space-y-3">
              <Label for="post-location-input">
                {{ t('post.composer.locationLabel') }}
              </Label>
              <Input
                id="post-location-input"
                v-model="location"
                :maxlength="MAX_LOCATION_LENGTH"
                :placeholder="t('post.composer.locationPlaceholder')"
              />
            </div>
          </PopoverContent>
        </Popover>

        <Popover>
          <PopoverTrigger as-child>
            <Button variant="ghost" size="icon">
              <SmilePlus class="h-4 w-4" />
            </Button>
          </PopoverTrigger>
          <PopoverContent class="w-64" align="start">
            <div class="grid grid-cols-4 gap-1">
              <Button
                v-for="emoji in quickEmojis"
                :key="emoji"
                variant="ghost"
                class="text-lg"
                @click="insertAtCursor(emoji)"
              >
                {{ emoji }}
              </Button>
            </div>
          </PopoverContent>
        </Popover>
      </div>

      <div class="flex items-center justify-end gap-3">
        <div class="relative h-8 w-8">
          <svg class="h-full w-full" viewBox="0 0 32 32">
            <circle
              cx="16"
              cy="16"
              r="14"
              fill="transparent"
              stroke="currentColor"
              stroke-width="2.5"
              class="text-muted"
            />
            <circle
              cx="16"
              cy="16"
              r="14"
              fill="transparent"
              stroke="currentColor"
              stroke-width="2.5"
              :stroke-dasharray="circumference"
              :stroke-dashoffset="progressOffset"
              :class="progressColorClass"
              class="origin-center -rotate-90 transform transition-all duration-300"
            />
          </svg>
          <span
            v-if="remainingCharacters <= 20"
            class="absolute inset-0 flex items-center justify-center text-[10px] font-semibold"
            :class="progressColorClass"
          >
            {{ remainingCharacters }}
          </span>
        </div>

        <AppSendButton
          class="h-10 px-5 font-semibold"
          :loading="isSubmitting"
          :disabled="isTweetDisabled"
          @click="handleSubmit"
        >
          {{
            isSubmitting
              ? t('post.composePage.submitting')
              : t('post.composer.publish')
          }}
        </AppSendButton>
      </div>
    </div>

    <input
      ref="fileInputRef"
      type="file"
      multiple
      accept="image/*,video/*"
      class="hidden"
      @change="handleFileSelect"
    />
  </div>
</template>
