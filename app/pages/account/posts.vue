<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import {
  BarChart3,
  Eye,
  FileText,
  Heart,
  Inbox,
  Loader2,
  MessageCircle,
  Pencil,
  Plus,
  RefreshCw,
  Repeat,
  Search,
  Sparkles,
  Trash2
} from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Skeleton } from '@/components/ui/skeleton';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow
} from '@/components/ui/table';
import type {
  PostAnalyticsVM,
  PostVM
} from '@/types/posts';
import type {
  V2PostSort,
  V2PostVisibility
} from '@/types/v2';
import {
  v2DeletePost,
  v2GetPostAnalytics,
  v2ListMyPosts,
  v2UpdatePost
} from '@/services/posts';

const { t, locale } = useAppLocale();
const localePath = useLocalePath();

type VisibilityFilter = V2PostVisibility | 'all';

interface EditForm {
  content: string;
  visibility: V2PostVisibility;
  language: string;
  location: string;
  tags: string;
}

const PILL_BASE =
  'inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium';

const posts = ref<PostVM[]>([]);
const selectedPost = ref<PostVM | null>(null);
const selectedAnalytics = ref<PostAnalyticsVM | null>(null);
const analyticsCache = ref<Record<number, PostAnalyticsVM>>({});
const loading = ref(false);
const analyticsLoading = ref(false);
const saving = ref(false);
const deleting = ref(false);
const page = ref(1);
const total = ref(0);
const hasNext = ref(false);
const pageSize = 12;

const search = ref('');
const sort = ref<V2PostSort>('newest');
const visibilityFilter = ref<VisibilityFilter>('all');
const deleteDialogOpen = ref(false);
const postToDelete = ref<PostVM | null>(null);

const editForm = ref<EditForm>({
  content: '',
  visibility: 'public',
  language: 'zh',
  location: '',
  tags: ''
});

const visibilityOptions: Array<{
  value: V2PostVisibility;
  labelKey: string;
}> = [
  {
    value: 'public',
    labelKey: 'post.composer.visibility.public'
  },
  {
    value: 'followers',
    labelKey: 'post.composer.visibility.followers'
  },
  {
    value: 'mentioned',
    labelKey: 'post.composer.visibility.mentioned'
  },
  {
    value: 'private',
    labelKey: 'post.composer.visibility.private'
  }
];

const languageOptions = [
  { value: 'zh', labelKey: 'account.posts.language.zh' },
  { value: 'en', labelKey: 'account.posts.language.en' },
  { value: 'ja', labelKey: 'account.posts.language.ja' },
  { value: 'ko', labelKey: 'account.posts.language.ko' }
];

const filteredPosts = computed(() => {
  if (visibilityFilter.value === 'all') return posts.value;
  return posts.value.filter(
    post => post.visibility === visibilityFilter.value
  );
});

const selectedStats = computed(() => {
  const post = selectedPost.value;
  const analytics = selectedAnalytics.value;
  if (!post) return null;
  return {
    views: analytics?.views ?? post.counts.views,
    likes: analytics?.likes ?? post.counts.likes,
    comments: analytics?.comments ?? post.counts.comments,
    replies: analytics?.replies ?? post.counts.replies,
    retweets: analytics?.retweets ?? post.counts.retweets,
    engagementScore:
      analytics?.engagementScore ?? post.counts.engagementScore,
    likeRate: analytics?.likeRate ?? 0
  };
});

const pageSummary = computed(() => {
  const visible = filteredPosts.value;
  return {
    totalPosts: total.value,
    visiblePosts: visible.length,
    views: visible.reduce(
      (sum, post) => sum + post.counts.views,
      0
    ),
    interactions: visible.reduce(
      (sum, post) =>
        sum +
        post.counts.likes +
        post.counts.comments +
        post.counts.replies +
        post.counts.retweets,
      0
    )
  };
});

function visibilityPillClass(value: string): string {
  switch (value) {
    case 'public':
      return `${PILL_BASE} border-sky-200/60 bg-sky-100/60 text-sky-700 dark:border-sky-900/40 dark:bg-sky-950/40 dark:text-sky-300`;
    case 'followers':
      return `${PILL_BASE} border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300`;
    case 'mentioned':
      return `${PILL_BASE} border-violet-200/60 bg-violet-100/60 text-violet-700 dark:border-violet-900/40 dark:bg-violet-950/40 dark:text-violet-300`;
    case 'private':
      return `${PILL_BASE} border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300`;
    default:
      return `${PILL_BASE} border-border/60 bg-muted/40 text-muted-foreground`;
  }
}

function normalizeVisibility(value: string): V2PostVisibility {
  return visibilityOptions.some(option => option.value === value)
    ? (value as V2PostVisibility)
    : 'public';
}

function visibilityLabel(value: string): string {
  const option = visibilityOptions.find(
    item => item.value === value
  );
  return option ? t(option.labelKey) : value;
}

function formatDate(value: string): string {
  if (!value) return '-';
  return new Date(value).toLocaleString(locale.value, {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit'
  });
}

function syncEditForm(post: PostVM): void {
  editForm.value = {
    content: post.content,
    visibility: normalizeVisibility(post.visibility),
    language: post.language || 'zh',
    location: post.location || '',
    tags: post.tags.join(', ')
  };
}

async function loadAnalytics(postId: number): Promise<void> {
  if (analyticsCache.value[postId]) {
    selectedAnalytics.value = analyticsCache.value[postId];
    return;
  }
  analyticsLoading.value = true;
  try {
    const analytics = await v2GetPostAnalytics(postId);
    analyticsCache.value = {
      ...analyticsCache.value,
      [postId]: analytics
    };
    if (selectedPost.value?.id === postId) {
      selectedAnalytics.value = analytics;
    }
  } catch (error) {
    toast.error(t('account.posts.feedback.analyticsFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    analyticsLoading.value = false;
  }
}

function selectPost(post: PostVM): void {
  selectedPost.value = post;
  selectedAnalytics.value = null;
  syncEditForm(post);
  void loadAnalytics(post.id);
}

async function loadPosts(reset = true): Promise<void> {
  loading.value = true;
  try {
    const nextPage = reset ? 1 : page.value + 1;
    const result = await v2ListMyPosts({
      page: nextPage,
      pageSize,
      sort: sort.value,
      q: search.value.trim() || undefined
    });
    posts.value = reset
      ? result.items
      : [...posts.value, ...result.items];
    page.value = result.page;
    total.value = result.total;
    hasNext.value = result.hasNext;

    const selectedStillExists =
      selectedPost.value &&
      posts.value.some(post => post.id === selectedPost.value?.id);
    if (!selectedStillExists && filteredPosts.value[0]) {
      selectPost(filteredPosts.value[0]);
    } else if (!selectedPost.value && filteredPosts.value[0]) {
      selectPost(filteredPosts.value[0]);
    }
  } catch (error) {
    toast.error(t('account.posts.feedback.loadFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    loading.value = false;
  }
}

async function saveSelectedPost(): Promise<void> {
  if (!selectedPost.value) return;
  saving.value = true;
  try {
    const tagNames = editForm.value.tags
      .split(',')
      .map(tag => tag.replace(/^#/, '').trim())
      .filter(Boolean);
    const updated = await v2UpdatePost(selectedPost.value.id, {
      content: editForm.value.content,
      visibility: editForm.value.visibility,
      language: editForm.value.language,
      location: editForm.value.location || null,
      tagNames
    });
    posts.value = posts.value.map(post =>
      post.id === updated.id ? updated : post
    );
    selectPost(updated);
    toast.success(t('account.posts.feedback.saved'));
  } catch (error) {
    toast.error(t('account.posts.feedback.saveFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    saving.value = false;
  }
}

function askDelete(post: PostVM): void {
  postToDelete.value = post;
  deleteDialogOpen.value = true;
}

async function confirmDelete(): Promise<void> {
  if (!postToDelete.value) return;
  deleting.value = true;
  try {
    const postId = postToDelete.value.id;
    await v2DeletePost(postId);
    posts.value = posts.value.filter(post => post.id !== postId);
    total.value = Math.max(0, total.value - 1);
    if (selectedPost.value?.id === postId) {
      selectedPost.value = null;
      selectedAnalytics.value = null;
      if (filteredPosts.value[0]) selectPost(filteredPosts.value[0]);
    }
    toast.success(t('post.feedback.deleted'));
    deleteDialogOpen.value = false;
    postToDelete.value = null;
  } catch (error) {
    toast.error(t('post.feedback.deleteFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    deleting.value = false;
  }
}

function openSelectedPost(post: PostVM): void {
  void navigateTo(localePath(`/tweet/${post.id}`));
}

function createPost(): void {
  void navigateTo(localePath('/meow'));
}

watch(visibilityFilter, () => {
  const selectedVisible =
    selectedPost.value &&
    filteredPosts.value.some(
      post => post.id === selectedPost.value?.id
    );
  if (!selectedVisible && filteredPosts.value[0]) {
    selectPost(filteredPosts.value[0]);
  }
});

onMounted(() => {
  void loadPosts(true);
});
</script>

<template>
  <div class="grid gap-4">
    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header
        class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"
      >
        <div class="flex items-start gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
          >
            <FileText class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h2 class="text-lg font-semibold tracking-tight">
              {{ t('account.posts.title') }}
            </h2>
            <p class="text-xs text-muted-foreground">
              {{ t('account.posts.description') }}
            </p>
          </div>
        </div>
        <div class="flex flex-wrap gap-2">
          <Button
            variant="outline"
            class="h-9 rounded-md shadow-xs"
            :disabled="loading"
            @click="loadPosts(true)"
          >
            <Loader2 v-if="loading" class="h-3.5 w-3.5 animate-spin" />
            <RefreshCw v-else class="h-3.5 w-3.5" />
            {{ t('common.refresh') }}
          </Button>
          <Button class="h-9 rounded-md shadow-xs" @click="createPost">
            <Plus class="h-3.5 w-3.5" />
            {{ t('account.posts.create') }}
          </Button>
        </div>
      </header>
    </section>

    <section class="grid gap-3 sm:grid-cols-2 md:grid-cols-4">
      <article
        class="grid gap-1.5 rounded-xl border border-border/60 bg-card p-4 shadow-none"
      >
        <div class="text-[11px] uppercase tracking-wider text-muted-foreground">
          {{ t('account.posts.stats.total') }}
        </div>
        <div class="text-2xl font-semibold tabular-nums">
          {{ pageSummary.totalPosts }}
        </div>
      </article>
      <article
        class="grid gap-1.5 rounded-xl border border-border/60 bg-card p-4 shadow-none"
      >
        <div class="text-[11px] uppercase tracking-wider text-muted-foreground">
          {{ t('account.posts.stats.visible') }}
        </div>
        <div class="text-2xl font-semibold tabular-nums">
          {{ pageSummary.visiblePosts }}
        </div>
      </article>
      <article
        class="grid gap-1.5 rounded-xl border border-border/60 bg-card p-4 shadow-none"
      >
        <div class="flex items-center gap-1.5 text-[11px] uppercase tracking-wider text-muted-foreground">
          <Eye class="h-3 w-3" />
          {{ t('account.posts.stats.views') }}
        </div>
        <div class="text-2xl font-semibold tabular-nums">
          {{ pageSummary.views }}
        </div>
      </article>
      <article
        class="grid gap-1.5 rounded-xl border border-border/60 bg-card p-4 shadow-none"
      >
        <div class="flex items-center gap-1.5 text-[11px] uppercase tracking-wider text-muted-foreground">
          <Sparkles class="h-3 w-3" />
          {{ t('account.posts.stats.interactions') }}
        </div>
        <div class="text-2xl font-semibold tabular-nums">
          {{ pageSummary.interactions }}
        </div>
      </article>
    </section>

    <section
      class="grid gap-3 rounded-xl border border-border/60 bg-card p-4 shadow-none lg:grid-cols-[minmax(0,1fr)_200px_180px_120px]"
    >
      <div class="relative">
        <Search
          class="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
        />
        <Input
          v-model="search"
          class="h-9 pl-9 shadow-xs"
          :placeholder="t('account.posts.searchPlaceholder')"
          @keyup.enter="loadPosts(true)"
        />
      </div>
      <Select v-model="sort" @update:model-value="loadPosts(true)">
        <SelectTrigger class="h-9 w-full rounded-md shadow-xs">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="newest">
            {{ t('account.posts.sort.newest') }}
          </SelectItem>
          <SelectItem value="oldest">
            {{ t('account.posts.sort.oldest') }}
          </SelectItem>
          <SelectItem value="popular">
            {{ t('account.posts.sort.popular') }}
          </SelectItem>
        </SelectContent>
      </Select>
      <Select v-model="visibilityFilter">
        <SelectTrigger class="h-9 w-full rounded-md shadow-xs">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">
            {{ t('account.posts.visibility.all') }}
          </SelectItem>
          <SelectItem
            v-for="option in visibilityOptions"
            :key="option.value"
            :value="option.value"
          >
            {{ t(option.labelKey) }}
          </SelectItem>
        </SelectContent>
      </Select>
      <Button
        variant="secondary"
        class="h-9 rounded-md shadow-xs"
        @click="loadPosts(true)"
      >
        {{ t('common.search') }}
      </Button>
    </section>

    <div
      class="grid min-h-[620px] gap-4 xl:grid-cols-[minmax(0,1fr)_28rem]"
    >
      <section
        class="grid min-w-0 overflow-hidden rounded-xl border border-border/60 bg-card shadow-none"
      >
        <header
          class="flex items-center justify-between gap-3 border-b border-border/60 bg-background/60 px-4 py-3 backdrop-blur"
        >
          <h3 class="text-sm font-semibold tracking-tight">
            {{
              t('account.posts.listTitle', {
                count: filteredPosts.length
              })
            }}
          </h3>
          <span
            :class="[
              PILL_BASE,
              'border-border/60 bg-muted/40 text-muted-foreground'
            ]"
          >
            {{ t('common.pagination', {
              page,
              totalPages: Math.max(1, Math.ceil(total / pageSize)),
              total
            }) }}
          </span>
        </header>

        <div class="p-3">
          <div
            v-if="loading && posts.length === 0"
            class="grid gap-3"
          >
            <Skeleton
              v-for="index in 4"
              :key="index"
              class="h-36 rounded-lg"
            />
          </div>

          <div
            v-else-if="filteredPosts.length === 0"
            class="flex min-h-[360px] flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-border/60 bg-muted/10 px-6 py-12 text-center"
          >
            <span
              class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
            >
              <Inbox class="h-5 w-5 text-muted-foreground" />
            </span>
            <div class="text-sm font-medium">
              {{ t('account.posts.emptyTitle') }}
            </div>
            <p class="max-w-sm text-xs text-muted-foreground">
              {{ t('account.posts.emptyDescription') }}
            </p>
            <Button
              class="mt-2 h-9 rounded-md shadow-xs"
              @click="createPost"
            >
              <Plus class="h-3.5 w-3.5" />
              {{ t('account.posts.create') }}
            </Button>
          </div>

          <ScrollArea v-else class="h-[min(640px,calc(100dvh-16rem))] rounded-md">
            <div class="pr-3">
              <Table class="min-w-[760px]">
                <TableHeader>
                  <TableRow class="border-border/60 bg-muted/20 hover:bg-muted/30">
                    <TableHead class="h-9 w-[42%] text-[11px] uppercase tracking-wider text-muted-foreground">
                      {{ t('account.posts.table.post') }}
                    </TableHead>
                    <TableHead class="h-9 text-[11px] uppercase tracking-wider text-muted-foreground">
                      {{ t('account.posts.form.visibility') }}
                    </TableHead>
                    <TableHead class="h-9 text-[11px] uppercase tracking-wider text-muted-foreground">
                      {{ t('account.posts.table.createdAt') }}
                    </TableHead>
                    <TableHead class="h-9 text-right text-[11px] uppercase tracking-wider text-muted-foreground">
                      {{ t('account.posts.table.metrics') }}
                    </TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  <TableRow
                    v-for="post in filteredPosts"
                    :key="post.id"
                    role="button"
                    tabindex="0"
                    class="cursor-pointer border-border/60 align-top transition-colors hover:bg-muted/30"
                    :class="
                      selectedPost?.id === post.id
                        ? 'bg-primary/5'
                        : ''
                    "
                    :data-state="
                      selectedPost?.id === post.id
                        ? 'selected'
                        : undefined
                    "
                    @click="selectPost(post)"
                    @keyup.enter="selectPost(post)"
                    @keyup.space="selectPost(post)"
                  >
                    <TableCell>
                      <div class="flex items-start gap-3">
                        <div
                          v-if="post.media.length > 0"
                          class="hidden h-16 w-20 shrink-0 overflow-hidden rounded-md border border-border/60 bg-muted sm:block"
                        >
                          <img
                            :src="post.media[0]?.thumbnailUrl || ''"
                            :alt="t('post.media.thumbnailAlt')"
                            class="h-full w-full object-cover"
                          />
                        </div>
                        <div class="min-w-0">
                          <div class="flex flex-wrap items-center gap-1.5">
                            <span
                              :class="[
                                PILL_BASE,
                                'border-border/60 bg-muted/40 text-muted-foreground'
                              ]"
                            >
                              {{ post.postType }}
                            </span>
                            <span class="font-mono text-[11px] text-muted-foreground">
                              #{{ post.id }}
                            </span>
                          </div>
                          <p class="mt-2 line-clamp-2 text-sm leading-relaxed">
                            {{
                              post.content ||
                              t('account.posts.emptyContent')
                            }}
                          </p>
                          <div
                            v-if="post.tags.length > 0"
                            class="mt-2 flex flex-wrap gap-1"
                          >
                            <span
                              v-for="tag in post.tags"
                              :key="tag"
                              :class="[
                                PILL_BASE,
                                'border-primary/20 bg-primary/5 text-primary'
                              ]"
                            >
                              #{{ tag }}
                            </span>
                          </div>
                        </div>
                      </div>
                    </TableCell>
                    <TableCell>
                      <span :class="visibilityPillClass(post.visibility)">
                        {{ visibilityLabel(post.visibility) }}
                      </span>
                    </TableCell>
                    <TableCell class="font-mono text-xs tabular-nums text-muted-foreground">
                      {{ formatDate(post.createdAt) }}
                    </TableCell>
                    <TableCell>
                      <div
                        class="grid min-w-44 grid-cols-2 gap-2 text-xs text-muted-foreground"
                      >
                        <span class="flex items-center gap-1 tabular-nums">
                          <Eye class="h-3.5 w-3.5" />
                          {{ post.counts.views }}
                        </span>
                        <span class="flex items-center gap-1 tabular-nums">
                          <Heart class="h-3.5 w-3.5" />
                          {{ post.counts.likes }}
                        </span>
                        <span class="flex items-center gap-1 tabular-nums">
                          <MessageCircle class="h-3.5 w-3.5" />
                          {{
                            post.counts.comments + post.counts.replies
                          }}
                        </span>
                        <span class="flex items-center gap-1 tabular-nums">
                          <Repeat class="h-3.5 w-3.5" />
                          {{ post.counts.retweets }}
                        </span>
                      </div>
                    </TableCell>
                  </TableRow>
                </TableBody>
              </Table>

              <div v-if="hasNext" class="flex justify-center pt-4">
                <Button
                  variant="outline"
                  class="h-9 rounded-md shadow-xs"
                  :disabled="loading"
                  @click="loadPosts(false)"
                >
                  <Loader2 v-if="loading" class="h-3.5 w-3.5 animate-spin" />
                  {{ loading ? t('common.loading') : t('common.loadMore') }}
                </Button>
              </div>
            </div>
          </ScrollArea>
        </div>
      </section>

      <section
        class="grid min-w-0 overflow-hidden rounded-xl border border-border/60 bg-card shadow-none"
      >
        <header
          class="flex items-start gap-3 border-b border-border/60 bg-background/60 px-5 py-4 backdrop-blur"
        >
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
          >
            <Pencil class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h3 class="text-base font-semibold tracking-tight">
              {{ t('account.posts.detailTitle') }}
            </h3>
            <p class="text-xs text-muted-foreground">
              {{ t('account.posts.detailDescription') }}
            </p>
          </div>
        </header>

        <div class="p-5">
          <div
            v-if="!selectedPost"
            class="flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-border/60 bg-muted/10 py-16 text-center"
          >
            <span
              class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
            >
              <BarChart3 class="h-5 w-5 text-muted-foreground" />
            </span>
            <p class="text-sm text-muted-foreground">
              {{ t('account.posts.noSelection') }}
            </p>
          </div>

          <div v-else class="grid gap-5">
            <div class="grid grid-cols-2 gap-3">
              <div
                v-for="metric in [
                  {
                    label: t('account.posts.metrics.views'),
                    value: selectedStats?.views ?? 0
                  },
                  {
                    label: t('account.posts.metrics.likes'),
                    value: selectedStats?.likes ?? 0
                  },
                  {
                    label: t('account.posts.metrics.comments'),
                    value: selectedStats?.comments ?? 0
                  },
                  {
                    label: t('account.posts.metrics.replies'),
                    value: selectedStats?.replies ?? 0
                  },
                  {
                    label: t('account.posts.metrics.retweets'),
                    value: selectedStats?.retweets ?? 0
                  },
                  {
                    label: t('account.posts.metrics.engagement'),
                    value: selectedStats?.engagementScore ?? 0
                  }
                ]"
                :key="metric.label"
                class="grid gap-0.5 rounded-lg border border-border/60 bg-muted/20 p-3"
              >
                <div class="text-[11px] uppercase tracking-wider text-muted-foreground">
                  {{ metric.label }}
                </div>
                <div class="text-lg font-semibold tabular-nums">
                  {{ metric.value }}
                </div>
              </div>
            </div>

            <div class="grid gap-0.5 rounded-lg border border-border/60 bg-muted/20 p-3">
              <div class="text-[11px] uppercase tracking-wider text-muted-foreground">
                {{ t('account.posts.metrics.likeRate') }}
              </div>
              <div class="text-lg font-semibold tabular-nums">
                {{
                  `${Math.round((selectedStats?.likeRate ?? 0) * 100)}%`
                }}
              </div>
              <div
                v-if="analyticsLoading"
                class="flex items-center gap-1.5 text-[11px] text-muted-foreground"
              >
                <Loader2 class="h-3 w-3 animate-spin" />
                {{ t('account.posts.loadingAnalytics') }}
              </div>
            </div>

            <div class="h-px w-full bg-border/60" />

            <div class="grid gap-2">
              <Label for="managed-post-content" class="text-xs font-medium">
                {{ t('account.posts.form.content') }}
              </Label>
              <Textarea
                id="managed-post-content"
                v-model="editForm.content"
                rows="7"
                class="resize-none shadow-xs"
              />
            </div>

            <div class="grid gap-3 sm:grid-cols-2">
              <div class="grid gap-2">
                <Label class="text-xs font-medium">
                  {{ t('account.posts.form.visibility') }}
                </Label>
                <Select v-model="editForm.visibility">
                  <SelectTrigger class="h-9 rounded-md shadow-xs">
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
              </div>

              <div class="grid gap-2">
                <Label class="text-xs font-medium">
                  {{ t('account.posts.form.language') }}
                </Label>
                <Select v-model="editForm.language">
                  <SelectTrigger class="h-9 rounded-md shadow-xs">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem
                      v-for="option in languageOptions"
                      :key="option.value"
                      :value="option.value"
                    >
                      {{ t(option.labelKey) }}
                    </SelectItem>
                  </SelectContent>
                </Select>
              </div>
            </div>

            <div class="grid gap-2">
              <Label for="managed-post-location" class="text-xs font-medium">
                {{ t('account.posts.form.location') }}
              </Label>
              <Input
                id="managed-post-location"
                v-model="editForm.location"
                class="h-9 shadow-xs"
                :placeholder="t('post.composer.locationPlaceholder')"
              />
            </div>

            <div class="grid gap-2">
              <Label for="managed-post-tags" class="text-xs font-medium">
                {{ t('account.posts.form.tags') }}
              </Label>
              <Input
                id="managed-post-tags"
                v-model="editForm.tags"
                class="h-9 shadow-xs"
                :placeholder="t('account.posts.form.tagsPlaceholder')"
              />
            </div>

            <div class="flex flex-wrap justify-between gap-2 border-t border-border/60 pt-4">
              <Button
                variant="outline"
                class="h-9 rounded-md shadow-xs"
                @click="openSelectedPost(selectedPost)"
              >
                <Eye class="h-3.5 w-3.5" />
                {{ t('account.posts.open') }}
              </Button>
              <div class="flex flex-wrap gap-2">
                <Button
                  variant="destructive"
                  class="h-9 rounded-md shadow-xs"
                  @click="askDelete(selectedPost)"
                >
                  <Trash2 class="h-3.5 w-3.5" />
                  {{ t('common.delete') }}
                </Button>
                <Button
                  class="h-9 rounded-md shadow-xs"
                  :disabled="saving"
                  @click="saveSelectedPost"
                >
                  <Loader2 v-if="saving" class="h-3.5 w-3.5 animate-spin" />
                  <Pencil v-else class="h-3.5 w-3.5" />
                  {{
                    saving
                      ? t('common.processing')
                      : t('account.posts.save')
                  }}
                </Button>
              </div>
            </div>
          </div>
        </div>
      </section>
    </div>

    <Dialog
      :open="deleteDialogOpen"
      @update:open="deleteDialogOpen = $event"
    >
      <DialogContent
        class="max-w-md overflow-hidden rounded-xl border-border/60 p-0"
      >
        <DialogHeader
          class="border-b border-border/60 bg-background/60 px-5 py-4 backdrop-blur"
        >
          <DialogTitle
            class="flex items-center gap-2 text-base font-semibold tracking-tight"
          >
            <span
              class="flex h-7 w-7 items-center justify-center rounded-md bg-rose-500/10 text-rose-600 dark:text-rose-400"
            >
              <Trash2 class="h-3.5 w-3.5" />
            </span>
            {{ t('post.delete.title') }}
          </DialogTitle>
          <DialogDescription class="text-xs">
            {{ t('post.delete.description') }}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter
          class="flex-col gap-2 border-t border-border/60 bg-muted/20 px-5 py-3 sm:flex-row"
        >
          <Button
            variant="outline"
            class="h-9 w-full rounded-md shadow-xs sm:w-auto"
            @click="deleteDialogOpen = false"
          >
            {{ t('common.cancel') }}
          </Button>
          <Button
            variant="destructive"
            class="h-9 w-full rounded-md shadow-xs sm:w-auto"
            :disabled="deleting"
            @click="confirmDelete"
          >
            <Loader2 v-if="deleting" class="h-3.5 w-3.5 animate-spin" />
            {{
              deleting ? t('common.processing') : t('common.delete')
            }}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  </div>
</template>
