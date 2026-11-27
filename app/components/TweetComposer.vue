<script setup lang="ts">
import PostPollEditor from '@/components/PostPollEditor.vue';
import PostDraftsDialog from '@/components/PostDraftsDialog.vue';
import { newPostPollDraft, openPostPollDraft, postPollPayload, type PostPollDraft } from '@/utils/post-poll-draft';
import { markdownBytes, markdownExcerpt, maxMarkdownBytes, validMarkdownBody } from '@/utils/post-markdown';
import {
  computed,
  defineAsyncComponent,
  nextTick,
  onBeforeUnmount,
  onMounted,
  ref,
  watch
} from 'vue';
import type { Component } from 'vue';
import type {
  CreatePostFormVM,
  PreviewPostVM
} from '@/types/posts';
import type { V2PostDraft, V2PostDraftInput, V2PostVisibility } from '@/types/v2';
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
import { Textarea } from '@/components/ui/textarea';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogTitle } from '@/components/ui/dialog';
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
  WandSparkles,
  X
} from 'lucide-vue-next';
import AppSendButton from '@/components/app/AppSendButton.vue';
import { toast } from 'vue-sonner';
import TweetPreviewCard from './TweetPreviewCard.vue';
import MentionPicker from './MentionPicker.vue';
import { v2DeleteMedia, v2UploadMedia } from '@/api/v2/posts';
import { v2PublishPostDraft, v2SavePostDraft } from '@/api/v2/post-drafts';
import { describeAiMedia, updateImageAltText, validImageAltText } from '@/api/v2/ai-vision';
import { usePreferenceStore } from '@/stores/user';
import { isPrivateMediaContent } from '@/utils/private-media';
import { authQueueFor } from '@/services/auth-request-queue';

interface MediaDraft {
  id: string;
  file: File;
  previewUrl: string;
  kind: 'image' | 'video';
  altText: string;
  description: string;
  mediaId?: number;
  uploadedAltText?: string;
  accessScope?: 'public' | 'post';
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
    initialDraft?: string;
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
  (e: 'draft-published'): void;
  (
    e: 'submit',
    form: CreatePostFormVM
  ): void;
}>();

const { t, locale } = useAppLocale();
const pollDraft = ref<PostPollDraft | null>(null);
const markdownEnabled = ref(false);
const draftListOpen = ref(false);
const savedDraftId = ref<number | null>(null);
const restoredMediaIds = ref<number[]>([]);
const restoredMentions = ref<{content: string; ids: number[]} | null>(null);

const MAX_CHARS = 280;
const MAX_MEDIA = 4;
const MAX_TAGS = 8;
const MAX_LOCATION_LENGTH = 60;
const toolbarButtonClass = 'flex size-8 shrink-0 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-muted hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-50';
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

const tweetContent = ref(props.initialDraft ?? '');
const visibility = ref<V2PostVisibility>('public');
const location = ref('');
const tagInput = ref('');
const manualTags = ref<string[]>([]);
const mediaDrafts = ref<MediaDraft[]>([]);
const preparingMedia = ref(false);
const describingImage = ref<string | null>(null);
const visionSuggestion = ref<{draftId:string;altText:string;tags:string[];selectedTags:string[]} | null>(null);
const deletingDraftId = ref<string | null>(null);
const mediaBusy = computed(() => props.isSubmitting || preparingMedia.value || deletingDraftId.value !== null);
const AiConversation = defineAsyncComponent(() => import('./AiConversation.vue'));
const writingOpen = ref(false);
const writingDraft = ref('');
let writingRevision = -1;
let assistantApplied = false;
const preferences = usePreferenceStore();
const app = useNuxtApp();
const auth = authQueueFor(app);
const draftRevision = auth.revision;
let mediaScope = 0;
let mediaUpload: AbortController | null = null;
let stopAuth: (() => void) | undefined;
watch(
  [
    () => preferences.isLoggedIn,
    () => preferences.preferences.user.id,
    () => preferences.preferences.authSession?.sessionId
  ],
  clearIdentityScope,
  { flush: 'sync' }
);
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
  () => markdownEnabled.value ? markdownBytes(tweetContent.value) : tweetContent.value.length
);
const bodyLimit = computed(() => markdownEnabled.value ? maxMarkdownBytes : MAX_CHARS);
const markdownReady = computed(() => !markdownEnabled.value || validMarkdownBody(tweetContent.value));

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
  uniqueValues([...parsedTags.value, ...manualTags.value]).slice(
    0,
    MAX_TAGS
  )
);

const activeMentions = computed(() =>
  selectedMentions.value.filter(mention =>
    tweetContent.value.includes(`@${mention.username}`)
  )
);

const mentionUserIds = computed(() =>
  uniqueNumbers([...(restoredMentions.value?.content === tweetContent.value ? restoredMentions.value.ids : []),
    ...activeMentions.value.map(item => item.userId)])
);

const isTweetDisabled = computed(() => {
  if (mediaBusy.value) return true;
  if (characterCount.value > bodyLimit.value || !markdownReady.value) return true;
  if (pollDraft.value && !postPollPayload(pollDraft.value)) return true;
  return !contentHasValue.value && mediaDrafts.value.length === 0 && restoredMediaIds.value.length === 0;
});

const remainingCharacters = computed(
  () => bodyLimit.value - characterCount.value
);

const circumference = 2 * Math.PI * 14;

const progressOffset = computed(() => {
  const progress = Math.min(
    characterCount.value / bodyLimit.value,
    1
  );
  return circumference * (1 - progress);
});

const progressColorClass = computed(() => {
  if (characterCount.value > bodyLimit.value) {
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

const contextIcon = computed(() =>
  props.replyTo ? MessageSquareReply : MessageSquareQuote
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

function createMediaDraftId(file: File): string {
  const randomPart =
    typeof crypto !== 'undefined' &&
    typeof crypto.randomUUID === 'function'
      ? crypto.randomUUID()
      : `${Date.now()}-${Math.random().toString(36).slice(2)}`;

  return `${file.name}-${file.size}-${file.lastModified}-${randomPart}`;
}

function updateVisibility(value: unknown): void {
  if (mediaBusy.value) return;
  if (
    value === 'public' ||
    value === 'followers' ||
    value === 'mentioned' ||
    value === 'private'
  ) {
    const scope = value === 'public' ? 'public' : 'post';
    if ((restoredMediaIds.value.length > 0 && (visibility.value === 'public') !== (value === 'public')) ||
        mediaDrafts.value.some(draft => draft.mediaId !== undefined && draft.accessScope !== scope)) {
      toast.error(t('media.attachmentScopeChanged'));
      return;
    }
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
  if (mediaBusy.value) return;
  const availableSlots = MAX_MEDIA - mediaDrafts.value.length - restoredMediaIds.value.length;
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
      id: createMediaDraftId(file),
      file,
      previewUrl: URL.createObjectURL(file),
      kind,
      altText: '',
      description: ''
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

async function removeMedia(draft: MediaDraft): Promise<void> {
  if (mediaBusy.value) return;
  const scope = mediaScope;
  deletingDraftId.value = draft.id;
  try {
    if (draft.mediaId !== undefined && savedDraftId.value === null) await v2DeleteMedia(draft.mediaId);
    if (scope !== mediaScope) return;
    URL.revokeObjectURL(draft.previewUrl);
    mediaDrafts.value = mediaDrafts.value.filter(item => item.id !== draft.id);
  } catch (error) {
    if (scope !== mediaScope) return;
    const conflict = error instanceof Error && 'statusCode' in error && error.statusCode === 409;
    toast.error(t(conflict ? 'post.composer.mediaInUse' : 'post.composer.mediaDeleteFailed'));
  } finally {
    if (scope === mediaScope) deletingDraftId.value = null;
  }
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
    const pickerWidth = Math.min(320, window.innerWidth - 16);
    mentionPickerPosition.value = {
      top: Math.min(rect.top + 72, window.innerHeight - 360),
      left: Math.max(
        8,
        Math.min(rect.left + 12, window.innerWidth - pickerWidth - 8)
      )
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

async function uploadMediaDraft(draft: MediaDraft, accessScope: 'public' | 'post', scope: number, signal: AbortSignal) {
  const alt = draft.altText.trim();
  if (draft.mediaId === undefined) {
    const body = new FormData();
    body.append('file', draft.file);
    if (accessScope === 'post') body.append('access_scope', 'post');
    if (alt) body.append('alt_text', alt);
    if (draft.description.trim()) body.append('description', draft.description.trim());
    const asset = await v2UploadMedia(body, signal);
    signal.throwIfAborted();
    if (scope !== mediaScope) throw new Error('Media draft changed');
    if (!Number.isSafeInteger(asset.media_id) || asset.media_id < 1 ||
        isPrivateMediaContent(asset.media_id, asset.public_url) !== (accessScope === 'post') ||
        (accessScope === 'post' && asset.thumbnail_url !== null)) {
      throw new Error(t('post.composePage.submitUnknownError'));
    }
    draft.mediaId = asset.media_id;
    draft.accessScope = accessScope;
    draft.uploadedAltText = alt;
  }
  if (draft.accessScope !== accessScope) throw new Error(t('media.attachmentScopeChanged'));
  return draft.mediaId;
}

async function suggestImageDetails(draft: MediaDraft) {
  if (mediaBusy.value || !preferences.isLoggedIn || auth.isIdentityChanging) return;
  const scope = mediaScope;
  const request = new AbortController();
  mediaUpload = request;
  preparingMedia.value = true;
  describingImage.value = draft.id;
  try {
    const id = await uploadMediaDraft(draft,visibility.value === 'public' ? 'public' : 'post',scope,request.signal);
    const result = await describeAiMedia(id,locale.value === 'en' ? 'en' : 'zh',request.signal);
    if (scope === mediaScope && !request.signal.aborted) {
      const tags = uniqueValues(result.tags.map(normalizeTagName));
      visionSuggestion.value = {draftId:draft.id,altText:result.alt_text,tags,selectedTags:[...tags]};
    }
  } catch {
    if (scope === mediaScope && !request.signal.aborted) toast.error(t('aiVision.unavailable'));
  } finally {
    if (mediaUpload === request) mediaUpload = null;
    if (scope === mediaScope) {
      preparingMedia.value = false;
      describingImage.value = null;
    }
  }
}

function applyImageDetails() {
  const suggestion = visionSuggestion.value;
  const draft = mediaDrafts.value.find(item => item.id === suggestion?.draftId);
  if (!suggestion || !draft || auth.isIdentityChanging || mediaBusy.value ||
      !suggestion.altText.trim() || !validImageAltText(suggestion.altText.trim())) return;
  draft.altText = suggestion.altText.trim();
  const additions = uniqueValues(suggestion.selectedTags.map(normalizeTagName))
    .filter(tag => !tagNames.value.includes(tag)).slice(0, MAX_TAGS - tagNames.value.length);
  manualTags.value.push(...additions);
  assistantApplied = true;
  visionSuggestion.value = null;
}

async function handleSubmit(purpose: 'publish' | 'save' = 'publish'): Promise<void> {
  if (mediaBusy.value || auth.isIdentityChanging || (purpose === 'publish' && isTweetDisabled.value)) return;
  if (purpose === 'save' && (props.replyTo || props.quoteTo || !preferences.isLoggedIn)) return;
  if (!markdownReady.value) return;
  const poll = postPollPayload(pollDraft.value);
  if (pollDraft.value && !poll) return;

  const draftContent = tweetContent.value;
  const markdown = markdownEnabled.value ? draftContent : undefined;
  const mediaIds = [...restoredMediaIds.value];
  const form: CreatePostFormVM = {
    ...(poll ? {poll} : {}),
    ...(markdown === undefined ? {} : {markdown}),
    content: markdown === undefined ? draftContent.trim() : markdownExcerpt(markdown),
    visibility: visibility.value,
    mediaIds,
    tagNames: tagNames.value,
    mentionUserIds: mentionUserIds.value,
    replyToPostId: props.replyTo?.id ?? null,
    repostOfPostId: null,
    quotedPostId: props.quoteTo?.id ?? null,
    location: location.value.trim() || undefined
  };

  const scope = mediaScope;
  const accessScope = form.visibility === 'public' ? 'public' : 'post';
  const upload = new AbortController();
  mediaUpload = upload;
  preparingMedia.value = true;
  try {
    for (const draft of mediaDrafts.value) {
      const mediaId = await uploadMediaDraft(draft,accessScope,scope,upload.signal);
      const alt = draft.altText.trim();
      if (draft.kind === 'image' && alt !== draft.uploadedAltText) {
        if (!validImageAltText(alt)) throw new Error(t('aiVision.invalidAlt'));
        await updateImageAltText(mediaId,alt,upload.signal);
        if (scope !== mediaScope) return;
        draft.uploadedAltText = alt;
      }
      mediaIds.push(mediaId);
    }
    if (purpose === 'save' || (savedDraftId.value !== null && !props.replyTo && !props.quoteTo)) {
      const payload: V2PostDraftInput = {group_id:null,content:markdown === undefined ? draftContent : markdownExcerpt(markdown),
        visibility:form.visibility,media_ids:mediaIds,tag_names:form.tagNames,mention_user_ids:form.mentionUserIds,
        location:form.location,poll,markdown};
      const saved = await app.runWithContext(() => v2SavePostDraft(payload,savedDraftId.value,upload.signal));
      if (scope !== mediaScope || upload.signal.aborted) return;
      savedDraftId.value = saved.draft_id;
      if (purpose === 'save') {
        toast.success(t('post.drafts.saved'));
        return;
      }
      await app.runWithContext(() => v2PublishPostDraft(saved.draft_id,upload.signal));
      if (scope !== mediaScope || upload.signal.aborted) return;
      reset();
      emit('draft-published');
    } else {
      emit('submit', form);
    }
  } catch (error) {
    if (scope !== mediaScope) return;
    toast.error(purpose === 'save' ? t('post.drafts.saveFailed') : t('post.composePage.publishFailed', {
      message: error instanceof Error ? error.message : t('post.composePage.submitUnknownError')
    }));
  } finally {
    if (mediaUpload === upload) mediaUpload = null;
    if (scope === mediaScope) preparingMedia.value = false;
  }
}

function resumeDraft(draft: V2PostDraft) {
  const { payload } = draft;
  if (payload.group_id !== null || mediaBusy.value || auth.isIdentityChanging) return;
  reset();
  savedDraftId.value = draft.draft_id;
  markdownEnabled.value = payload.markdown !== undefined;
  tweetContent.value = payload.markdown ?? payload.content;
  visibility.value = payload.visibility ?? 'public';
  location.value = payload.location ?? '';
  manualTags.value = [...(payload.tag_names ?? [])];
  restoredMediaIds.value = [...(payload.media_ids ?? [])];
  restoredMentions.value = {content:tweetContent.value,ids:[...(payload.mention_user_ids ?? [])]};
  pollDraft.value = payload.poll ? openPostPollDraft(payload.poll) : null;
}

function reset(): void {
  writingOpen.value = false;
  assistantApplied = false;
  tweetContent.value = '';
  visibility.value = 'public';
  location.value = '';
  tagInput.value = '';
  manualTags.value = [];
  pollDraft.value = null;
  markdownEnabled.value = false;
  selectedMentions.value = [];
  showMentionPicker.value = false;
  clearScope();
}

function clearIdentityScope(): void {
  writingOpen.value = false;
  writingDraft.value = '';
  pollDraft.value = null;
  draftListOpen.value = false;
  if (props.initialDraft || assistantApplied || savedDraftId.value !== null || markdownEnabled.value) reset();
  else clearScope();
}

function openWritingAssistant(): void {
  if (mediaBusy.value || !preferences.isLoggedIn || auth.isIdentityChanging) return;
  writingDraft.value = tweetContent.value;
  writingRevision = auth.revision;
  writingOpen.value = true;
}

function applyWritingDraft(text: string): void {
  if (!writingOpen.value || mediaBusy.value || !preferences.isLoggedIn || auth.isIdentityChanging ||
      auth.revision !== writingRevision || tweetContent.value !== writingDraft.value ||
      !text.trim() || text.length > MAX_CHARS) return;
  tweetContent.value = text;
  assistantApplied = true;
  writingOpen.value = false;
}

watch(writingOpen, open => { if (!open) writingDraft.value = ''; });
watch([() => props.replyTo?.id, () => props.quoteTo?.id], () => {
  writingOpen.value = false;
  pollDraft.value = null;
  markdownEnabled.value = false;
  if (savedDraftId.value !== null) reset();
}, { flush: 'sync' });

function clearScope(): void {
  mediaScope++;
  mediaUpload?.abort();
  mediaUpload = null;
  preparingMedia.value = false;
  describingImage.value = null;
  visionSuggestion.value = null;
  deletingDraftId.value = null;
  savedDraftId.value = null;
  restoredMediaIds.value = [];
  restoredMentions.value = null;
  mediaDrafts.value.forEach(draft => {
    URL.revokeObjectURL(draft.previewUrl);
  });
  mediaDrafts.value = [];
}

onMounted(() => {
  if (props.initialDraft && (auth.isIdentityChanging || auth.revision !== draftRevision)) reset();
  stopAuth = auth.subscribe(clearIdentityScope);
});
onBeforeUnmount(() => {
  stopAuth?.();
  clearScope();
});

defineExpose({
  reset
});
</script>

<template>
  <div
    class="mobile-scroll-safe @container rounded-[24px] bg-card shadow-[0_2px_18px_rgba(15,23,42,0.04)] dark:shadow-none"
    @drop="handleDrop"
    @dragover.prevent="isDraggingMedia = true"
    @dragleave="isDraggingMedia = false"
  >
    <div class="space-y-3.5 p-4 sm:p-5">
      <div
        v-if="contextPost"
        class="rounded-2xl bg-secondary/45 p-3"
      >
        <div class="mb-2 flex items-center justify-between gap-3">
          <span
            class="inline-flex items-center gap-1 rounded-full bg-card px-2.5 py-0.5 text-[11px] font-medium text-muted-foreground"
          >
            <component :is="contextIcon" class="h-3 w-3" />
            {{ contextLabel }}
          </span>
          <button
            type="button"
            class="flex h-7 w-7 items-center justify-center rounded-full text-muted-foreground transition hover:bg-secondary hover:text-foreground"
            :aria-label="t('post.composer.clearContext')"
            @click="clearContext"
          >
            <X class="h-4 w-4" />
          </button>
        </div>
        <TweetPreviewCard :tweet="contextPost" />
      </div>

      <div
        class="relative rounded-2xl transition-colors"
        :class="{
          'bg-primary/5 ring-2 ring-primary/15':
            isDraggingMedia
        }"
      >
        <Textarea
          v-model="tweetContent"
          :placeholder="t('post.composer.placeholder')"
          class="min-h-40 resize-none border-0 bg-transparent p-1 text-base leading-relaxed shadow-none focus-visible:ring-0 md:text-base"
          @input="handleInput"
          @keydown="handleKeyDown"
          @paste="handlePaste"
        />
        <div
          class="pointer-events-none absolute inset-x-2 bottom-2 text-xs text-muted-foreground"
          :class="{ hidden: !isDraggingMedia }"
        >
          {{ t('post.composer.dropHint') }}
        </div>
      </div>

      <div v-if="!replyTo && !quoteTo" class="flex flex-wrap items-center gap-1.5">
        <Button
          v-if="!pollDraft"
          type="button"
          size="sm"
          variant="secondary"
          class="rounded-full bg-secondary/70 px-3 text-xs shadow-none"
          :disabled="mediaBusy"
          @click="pollDraft = newPostPollDraft()"
        >
          {{ t('post.poll.add') }}
        </Button>
        <Button
          type="button"
          size="sm"
          variant="secondary"
          class="rounded-full bg-secondary/70 px-3 text-xs shadow-none aria-pressed:bg-primary/15 aria-pressed:text-primary"
          :aria-pressed="markdownEnabled"
          :disabled="mediaBusy"
          @click="markdownEnabled = !markdownEnabled"
        >
          {{ t('post.markdown.mode') }}
        </Button>
        <template v-if="preferences.isLoggedIn">
          <Button type="button" size="sm" variant="secondary" class="rounded-full bg-secondary/70 px-3 text-xs shadow-none" :disabled="mediaBusy" @click="draftListOpen = true">{{ t('post.drafts.title') }}</Button>
          <Button type="button" size="sm" variant="secondary" class="rounded-full bg-secondary/70 px-3 text-xs shadow-none" :disabled="mediaBusy || !markdownReady || (!!pollDraft && !postPollPayload(pollDraft))" @click="handleSubmit('save')">{{ t('post.drafts.save') }}</Button>
          <span v-if="savedDraftId !== null" class="text-xs text-muted-foreground">{{ t('post.drafts.editing') }}</span>
        </template>
        <span v-if="markdownEnabled" class="text-xs" :class="characterCount > bodyLimit ? 'text-destructive' : 'text-muted-foreground'">
          {{ t('post.markdown.size', {used:characterCount,limit:bodyLimit}) }}
        </span>
      </div>
      <PostPollEditor
        v-if="!replyTo && !quoteTo && pollDraft"
        v-model="pollDraft"
        :disabled="mediaBusy"
      />
      <PostDraftsDialog v-model:open="draftListOpen" :group-id="0" @resume="resumeDraft"
        @removed="id => { if (id === savedDraftId) savedDraftId = null }" />
      <ul v-if="restoredMediaIds.length" class="flex flex-wrap gap-2">
        <li v-for="(id,index) in restoredMediaIds" :key="id" class="flex items-center gap-2 rounded-full bg-secondary px-3 py-1 text-xs">
          <span>{{ t('post.drafts.attachment', {index:index+1}) }}</span>
          <Button type="button" size="icon" variant="ghost" class="size-5 rounded-full" :disabled="mediaBusy"
            :aria-label="t('post.drafts.removeAttachment')" @click="restoredMediaIds = restoredMediaIds.filter(item => item !== id)"><X class="size-3.5" /></Button>
        </li>
      </ul>

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
          v-for="draft in mediaDrafts"
          :key="draft.id"
          class="group/media overflow-hidden rounded-2xl bg-secondary/45"
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
              class="pointer-events-none absolute inset-0 flex items-center justify-center bg-black/25"
            >
              <PlayCircle class="h-10 w-10 text-white/90" />
            </div>
            <button
              type="button"
              class="absolute right-2 top-2 flex h-7 w-7 items-center justify-center rounded-full bg-background/90 text-foreground opacity-0 shadow-sm ring-1 ring-border/60 transition group-hover/media:opacity-100 hover:bg-background"
              :aria-label="t('post.composer.removeMedia')"
              :disabled="mediaBusy"
              @click="removeMedia(draft)"
            >
              <X class="h-3.5 w-3.5" />
            </button>
          </div>
          <div class="space-y-2 p-3">
            <div class="flex items-center justify-between gap-2">
              <span class="truncate text-[11px] text-muted-foreground">
                {{ draft.file.name }}
              </span>
              <span
                class="shrink-0 text-[11px] tabular-nums text-muted-foreground"
              >
                {{ formatFileSize(draft.file.size) }}
              </span>
            </div>
            <Input
              v-model="draft.altText"
              :disabled="mediaBusy || (draft.kind !== 'image' && draft.mediaId !== undefined)"
              :placeholder="t('post.composer.altTextPlaceholder')"
              maxlength="500"
              class="h-8 rounded-xl border-0 bg-card/80 text-xs shadow-none"
            />
            <Input
              v-model="draft.description"
              :disabled="mediaBusy || draft.mediaId !== undefined"
              :placeholder="
                t('post.composer.mediaDescriptionPlaceholder')
              "
              maxlength="240"
              class="h-8 rounded-xl border-0 bg-card/80 text-xs shadow-none"
            />
            <Button v-if="draft.kind === 'image' && ['image/jpeg','image/png','image/webp'].includes(draft.file.type)"
              type="button" size="sm" variant="secondary" class="rounded-full" :disabled="mediaBusy" @click="suggestImageDetails(draft)">
              <WandSparkles class="size-4" aria-hidden="true" />
              {{ describingImage === draft.id ? t('aiVision.generating') : t('aiVision.suggest') }}
            </Button>
          </div>
        </div>
      </div>

      <Dialog :open="!!visionSuggestion" @update:open="open => { if (!open) visionSuggestion = null; }">
        <DialogContent v-if="visionSuggestion">
          <DialogTitle>{{ t('aiVision.suggest') }}</DialogTitle>
          <DialogDescription>{{ t('aiVision.review') }}</DialogDescription>
          <div class="grid gap-3">
            <label class="grid gap-2 text-sm">
              {{ t('aiVision.altText') }}
              <Textarea v-model="visionSuggestion.altText" maxlength="500" rows="3" />
            </label>
            <div v-if="visionSuggestion.tags.length" class="flex flex-wrap gap-3">
              <label v-for="tag in visionSuggestion.tags" :key="tag" class="flex items-center gap-1 text-sm">
                <input v-model="visionSuggestion.selectedTags" type="checkbox" :value="tag">
                #{{ tag }}
              </label>
            </div>
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" @click="visionSuggestion = null">{{ t('aiVision.cancel') }}</Button>
            <Button type="button"
              :disabled="!visionSuggestion.altText.trim() || !validImageAltText(visionSuggestion.altText.trim())"
              @click="applyImageDetails">{{ t('aiVision.apply') }}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <div
        v-if="
          tagNames.length > 0 ||
          activeMentions.length > 0 ||
          location.trim()
        "
        class="flex flex-wrap gap-1.5"
      >
        <span
          v-for="tag in tagNames"
          :key="`tag-${tag}`"
          class="inline-flex items-center gap-1 rounded-full bg-secondary px-2.5 py-0.5 text-[11px] font-medium text-muted-foreground"
        >
          <Hash class="h-3 w-3" />
          {{ tag }}
          <button
            v-if="manualTags.includes(tag)"
            type="button"
            class="ml-0.5 flex h-3.5 w-3.5 items-center justify-center rounded-full text-muted-foreground transition hover:bg-muted hover:text-foreground"
            :aria-label="`${t('common.delete')} ${tag}`"
            @click="removeManualTag(tag)"
          >
            <X class="h-3 w-3" />
          </button>
        </span>
        <span
          v-for="mention in activeMentions"
          :key="`mention-${mention.userId}`"
          class="inline-flex items-center gap-1 rounded-full bg-sky-500/12 px-2.5 py-0.5 text-[11px] font-medium text-sky-700 dark:text-sky-300"
        >
          <AtSign class="h-3 w-3" />
          {{ mention.displayName }}
          <button
            type="button"
            class="ml-0.5 flex h-3.5 w-3.5 items-center justify-center rounded-full transition hover:bg-sky-200/60 dark:hover:bg-sky-900/40"
            :aria-label="`${t('common.delete')} ${mention.displayName}`"
            @click="removeMention(mention.username)"
          >
            <X class="h-3 w-3" />
          </button>
        </span>
        <span
          v-if="location.trim()"
          class="inline-flex items-center gap-1 rounded-full bg-emerald-500/12 px-2.5 py-0.5 text-[11px] font-medium text-emerald-700 dark:text-emerald-300"
        >
          <MapPin class="h-3 w-3" />
          {{ location.trim() }}
          <button
            type="button"
            class="ml-0.5 flex h-3.5 w-3.5 items-center justify-center rounded-full transition hover:bg-emerald-200/60 dark:hover:bg-emerald-900/40"
            :aria-label="`${t('common.delete')} ${location}`"
            @click="location = ''"
          >
            <X class="h-3 w-3" />
          </button>
        </span>
      </div>
    </div>

    <div
      class="flex flex-wrap items-center justify-between gap-2 border-t border-border/60 px-4 pb-4 pt-1 sm:px-5 @xl:flex-nowrap @xl:px-4"
    >
      <div class="flex flex-wrap items-center gap-1 [&_button]:rounded-full">
        <TooltipProvider>
          <Tooltip v-if="preferences.isLoggedIn">
            <TooltipTrigger as-child>
              <button type="button" :disabled="mediaBusy"
                :class="toolbarButtonClass"
                :aria-label="t('aiWriting.title')" @click="openWritingAssistant">
                <WandSparkles class="h-4 w-4" />
              </button>
            </TooltipTrigger>
            <TooltipContent>{{ t('aiWriting.title') }}</TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger as-child>
              <button
                type="button"
                :class="toolbarButtonClass"
                :aria-label="t('post.composer.addMedia')"
                @click="triggerFileInput"
              >
                <ImageUp class="h-4 w-4" />
              </button>
            </TooltipTrigger>
            <TooltipContent>
              {{ t('post.composer.addMedia') }}
            </TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger as-child>
              <button
                type="button"
                :class="toolbarButtonClass"
                :aria-label="t('post.composer.replyPost')"
                @click="emit('open-reply-dialog')"
              >
                <MessageSquareReply class="h-4 w-4" />
              </button>
            </TooltipTrigger>
            <TooltipContent>
              {{ t('post.composer.replyPost') }}
            </TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger as-child>
              <button
                type="button"
                :class="toolbarButtonClass"
                :aria-label="t('post.composer.quotePost')"
                @click="emit('open-quote-dialog')"
              >
                <MessageSquareQuote class="h-4 w-4" />
              </button>
            </TooltipTrigger>
            <TooltipContent>
              {{ t('post.composer.quotePost') }}
            </TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger as-child>
              <button
                type="button"
                :class="toolbarButtonClass"
                :aria-label="t('post.composer.addMention')"
                @click="startMention"
              >
                <AtSign class="h-4 w-4" />
              </button>
            </TooltipTrigger>
            <TooltipContent>
              {{ t('post.composer.addMention') }}
            </TooltipContent>
          </Tooltip>

          <Popover>
            <Tooltip>
              <TooltipTrigger as-child>
                <PopoverTrigger as-child>
                  <button type="button" :class="toolbarButtonClass" :aria-label="t('post.composer.addTag')">
                    <Hash class="size-4" aria-hidden="true" />
                  </button>
                </PopoverTrigger>
              </TooltipTrigger>
              <TooltipContent>{{ t('post.composer.addTag') }}</TooltipContent>
            </Tooltip>
            <PopoverContent
              class="w-[min(18rem,calc(100vw-1rem))] rounded-2xl border-0 p-3"
              align="start"
            >
              <div class="grid gap-2">
                <Label
                  for="post-tag-input"
                  class="text-xs font-medium"
                >
                  {{ t('post.composer.tagLabel') }}
                </Label>
                <div class="flex gap-2">
                  <Input
                    id="post-tag-input"
                    v-model="tagInput"
                    :placeholder="
                      t('post.composer.tagPlaceholder')
                    "
                    maxlength="32"
                    class="h-9 rounded-xl border-0 bg-secondary/70 shadow-none"
                    @keydown.enter.prevent="addManualTag"
                  />
                  <Button
                    type="button"
                    size="icon"
                    class="h-9 w-9 shrink-0 rounded-full shadow-none"
                    :aria-label="t('post.composer.addTag')"
                    @click="addManualTag"
                  >
                    <Plus class="h-4 w-4" />
                  </Button>
                </div>
              </div>
            </PopoverContent>
          </Popover>

          <Popover>
            <Tooltip>
              <TooltipTrigger as-child>
                <PopoverTrigger as-child>
                  <button type="button" :class="toolbarButtonClass" :aria-label="t('post.composer.addLocation')">
                    <MapPin class="size-4" aria-hidden="true" />
                  </button>
                </PopoverTrigger>
              </TooltipTrigger>
              <TooltipContent>{{ t('post.composer.addLocation') }}</TooltipContent>
            </Tooltip>
            <PopoverContent
              class="w-[min(20rem,calc(100vw-1rem))] rounded-2xl border-0 p-3"
              align="start"
            >
              <div class="grid gap-2">
                <Label
                  for="post-location-input"
                  class="text-xs font-medium"
                >
                  {{ t('post.composer.locationLabel') }}
                </Label>
                <Input
                  id="post-location-input"
                  v-model="location"
                  :maxlength="MAX_LOCATION_LENGTH"
                  :placeholder="
                    t('post.composer.locationPlaceholder')
                  "
                  class="h-9 rounded-xl border-0 bg-secondary/70 shadow-none"
                />
              </div>
            </PopoverContent>
          </Popover>

          <Popover>
            <Tooltip>
              <TooltipTrigger as-child>
                <PopoverTrigger as-child>
                  <button type="button" :class="toolbarButtonClass" :aria-label="t('chat.actions.emoji')">
                    <SmilePlus class="size-4" />
                  </button>
                </PopoverTrigger>
              </TooltipTrigger>
              <TooltipContent>{{ t('chat.actions.emoji') }}</TooltipContent>
            </Tooltip>
            <PopoverContent
              class="w-[min(16rem,calc(100vw-1rem))] rounded-xl border-border/60 p-2"
              align="start"
            >
              <div class="grid grid-cols-4 gap-1">
                <button
                  v-for="emoji in quickEmojis"
                  :key="emoji"
                  type="button"
                  class="flex h-9 items-center justify-center rounded-md text-lg transition hover:bg-muted"
                  @click="insertAtCursor(emoji)"
                >
                  {{ emoji }}
                </button>
              </div>
            </PopoverContent>
          </Popover>
        </TooltipProvider>
      </div>

      <div class="ml-auto flex max-w-full flex-wrap items-center justify-end gap-2 @xl:shrink-0">
        <Select
          :model-value="visibility"
          :disabled="mediaBusy"
          @update:model-value="updateVisibility"
        >
          <SelectTrigger
            size="sm"
            class="h-8 w-auto shrink-0 gap-1.5 rounded-full border-0 bg-secondary px-3 text-xs shadow-none hover:bg-accent dark:bg-secondary dark:hover:bg-accent"
            :aria-label="t('account.posts.form.visibility')"
          >
            <component
              :is="selectedVisibility.icon"
              class="size-3.5 text-muted-foreground"
            />
            <SelectValue />
          </SelectTrigger>
          <SelectContent class="rounded-2xl">
            <SelectItem
              v-for="option in visibilityOptions"
              :key="option.value"
              :value="option.value"
              class="rounded-xl"
            >
              {{ t(option.labelKey) }}
            </SelectItem>
          </SelectContent>
        </Select>

        <div v-if="characterCount > 0" class="relative size-8 shrink-0">
          <svg class="h-full w-full" viewBox="0 0 32 32" aria-hidden="true">
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
            class="absolute inset-0 flex items-center justify-center text-[10px] font-semibold tabular-nums"
            :class="progressColorClass"
          >
            {{ remainingCharacters }}
          </span>
        </div>

        <AppSendButton
          class="h-9 shrink-0 rounded-full px-5 font-semibold shadow-none"
          :loading="isSubmitting || preparingMedia"
          :disabled="isTweetDisabled"
          @click="handleSubmit()"
        >
          {{
            isSubmitting || preparingMedia
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
    <Dialog v-model:open="writingOpen">
      <DialogContent class="max-h-[90dvh] overflow-y-auto p-0 sm:max-h-[90dvh] sm:w-[calc(100%-2rem)] sm:max-w-5xl sm:p-0">
        <DialogTitle class="sr-only">{{ t('aiWriting.title') }}</DialogTitle>
        <DialogDescription class="sr-only">{{ t('aiWriting.composerSource') }}</DialogDescription>
        <AiConversation v-if="writingOpen" purpose="writing" :composer-draft="writingDraft" @apply-draft="applyWritingDraft" />
      </DialogContent>
    </Dialog>
  </div>
</template>
