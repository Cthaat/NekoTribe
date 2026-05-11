<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import {
  BarChart3,
  Eye,
  Heart,
  MessageCircle,
  Pencil,
  Plus,
  RefreshCw,
  Repeat,
  Search,
  Trash2
} from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle
} from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
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
import { Separator } from '@/components/ui/separator';
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
  <div class="space-y-5">
    <div
      class="flex flex-col gap-4 rounded-lg border bg-card/70 p-4 shadow-sm lg:flex-row lg:items-center lg:justify-between"
    >
      <div>
        <h2 class="text-2xl font-semibold tracking-tight">
          {{ t('account.posts.title') }}
        </h2>
        <p class="text-sm text-muted-foreground">
          {{ t('account.posts.description') }}
        </p>
      </div>
      <div class="flex flex-wrap gap-2">
        <Button
          variant="outline"
          class="gap-2"
          :disabled="loading"
          @click="loadPosts(true)"
        >
          <RefreshCw
            class="h-4 w-4"
            :class="{ 'animate-spin': loading }"
          />
          {{ t('common.refresh') }}
        </Button>
        <Button class="gap-2" @click="createPost">
          <Plus class="h-4 w-4" />
          {{ t('account.posts.create') }}
        </Button>
      </div>
    </div>

    <div class="grid gap-3 md:grid-cols-4">
      <div class="rounded-lg border bg-card p-4">
        <div class="text-xs text-muted-foreground">
          {{ t('account.posts.stats.total') }}
        </div>
        <div class="mt-1 text-2xl font-semibold">
          {{ pageSummary.totalPosts }}
        </div>
      </div>
      <div class="rounded-lg border bg-card p-4">
        <div class="text-xs text-muted-foreground">
          {{ t('account.posts.stats.visible') }}
        </div>
        <div class="mt-1 text-2xl font-semibold">
          {{ pageSummary.visiblePosts }}
        </div>
      </div>
      <div class="rounded-lg border bg-card p-4">
        <div class="text-xs text-muted-foreground">
          {{ t('account.posts.stats.views') }}
        </div>
        <div class="mt-1 text-2xl font-semibold">
          {{ pageSummary.views }}
        </div>
      </div>
      <div class="rounded-lg border bg-card p-4">
        <div class="text-xs text-muted-foreground">
          {{ t('account.posts.stats.interactions') }}
        </div>
        <div class="mt-1 text-2xl font-semibold">
          {{ pageSummary.interactions }}
        </div>
      </div>
    </div>

    <div
      class="grid gap-3 rounded-lg border bg-card/70 p-3 lg:grid-cols-[minmax(0,1fr)_220px_180px_180px]"
    >
      <div class="relative">
        <Search
          class="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
        />
        <Input
          v-model="search"
          class="pl-9"
          :placeholder="t('account.posts.searchPlaceholder')"
          @keyup.enter="loadPosts(true)"
        />
      </div>
      <Select v-model="sort" @update:model-value="loadPosts(true)">
        <SelectTrigger>
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
        <SelectTrigger>
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
      <Button variant="secondary" @click="loadPosts(true)">
        {{ t('common.search') }}
      </Button>
    </div>

    <div class="grid min-h-[620px] gap-5 xl:grid-cols-[minmax(0,1fr)_28rem]">
      <div class="min-w-0 rounded-lg border bg-card/60 p-3">
        <div class="mb-3 flex items-center justify-between">
          <div class="text-sm font-medium">
            {{
              t('account.posts.listTitle', {
                count: filteredPosts.length
              })
            }}
          </div>
          <Badge variant="outline">
            {{ t('common.pagination', {
              page,
              totalPages: Math.max(1, Math.ceil(total / pageSize)),
              total
            }) }}
          </Badge>
        </div>

        <div
          v-if="loading && posts.length === 0"
          class="grid gap-3"
        >
          <div
            v-for="index in 4"
            :key="index"
            class="h-36 animate-pulse rounded-lg bg-muted"
          />
        </div>

        <div
          v-else-if="filteredPosts.length === 0"
          class="flex min-h-[360px] flex-col items-center justify-center rounded-lg border border-dashed bg-muted/20 px-6 text-center"
        >
          <BarChart3 class="mb-3 h-9 w-9 text-muted-foreground" />
          <div class="font-medium">
            {{ t('account.posts.emptyTitle') }}
          </div>
          <p class="mt-1 max-w-sm text-sm text-muted-foreground">
            {{ t('account.posts.emptyDescription') }}
          </p>
          <Button class="mt-4 gap-2" @click="createPost">
            <Plus class="h-4 w-4" />
            {{ t('account.posts.create') }}
          </Button>
        </div>

        <ScrollArea v-else class="h-[640px] rounded-md">
          <div class="space-y-3 pr-3">
            <button
              v-for="post in filteredPosts"
              :key="post.id"
              type="button"
              class="w-full rounded-lg border bg-background p-4 text-left transition-colors hover:bg-muted/40"
              :class="
                selectedPost?.id === post.id
                  ? 'border-primary/60 ring-1 ring-primary/20'
                  : 'border-border'
              "
              @click="selectPost(post)"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <Badge variant="secondary">
                      {{ post.postType }}
                    </Badge>
                    <Badge variant="outline">
                      {{ visibilityLabel(post.visibility) }}
                    </Badge>
                    <span class="text-xs text-muted-foreground">
                      {{ formatDate(post.createdAt) }}
                    </span>
                  </div>
                  <p class="mt-3 line-clamp-3 text-sm leading-6">
                    {{
                      post.content ||
                      t('account.posts.emptyContent')
                    }}
                  </p>
                </div>
                <div
                  v-if="post.media.length > 0"
                  class="hidden h-20 w-24 shrink-0 overflow-hidden rounded-md border bg-muted sm:block"
                >
                  <img
                    :src="post.media[0]?.thumbnailUrl || ''"
                    :alt="t('post.media.thumbnailAlt')"
                    class="h-full w-full object-cover"
                  />
                </div>
              </div>

              <div
                v-if="post.tags.length > 0"
                class="mt-3 flex flex-wrap gap-1"
              >
                <Badge
                  v-for="tag in post.tags"
                  :key="tag"
                  variant="outline"
                >
                  #{{ tag }}
                </Badge>
              </div>

              <div
                class="mt-4 grid grid-cols-5 gap-2 text-xs text-muted-foreground"
              >
                <span class="flex items-center gap-1">
                  <Eye class="h-3.5 w-3.5" />
                  {{ post.counts.views }}
                </span>
                <span class="flex items-center gap-1">
                  <Heart class="h-3.5 w-3.5" />
                  {{ post.counts.likes }}
                </span>
                <span class="flex items-center gap-1">
                  <MessageCircle class="h-3.5 w-3.5" />
                  {{ post.counts.comments + post.counts.replies }}
                </span>
                <span class="flex items-center gap-1">
                  <Repeat class="h-3.5 w-3.5" />
                  {{ post.counts.retweets }}
                </span>
                <span class="text-right">
                  {{ post.counts.engagementScore }}
                </span>
              </div>
            </button>

            <div v-if="hasNext" class="flex justify-center pt-2">
              <Button
                variant="outline"
                :disabled="loading"
                @click="loadPosts(false)"
              >
                {{ t('common.loadMore') }}
              </Button>
            </div>
          </div>
        </ScrollArea>
      </div>

      <Card class="min-w-0 gap-0 overflow-hidden py-0">
        <CardHeader class="border-b px-5 py-4 !pb-4">
          <CardTitle class="flex items-center gap-2 text-base">
            <Pencil class="h-4 w-4" />
            {{ t('account.posts.detailTitle') }}
          </CardTitle>
          <CardDescription>
            {{ t('account.posts.detailDescription') }}
          </CardDescription>
        </CardHeader>
        <CardContent class="p-5">
          <div v-if="!selectedPost" class="py-16 text-center">
            <BarChart3 class="mx-auto h-8 w-8 text-muted-foreground" />
            <p class="mt-3 text-sm text-muted-foreground">
              {{ t('account.posts.noSelection') }}
            </p>
          </div>

          <div v-else class="space-y-5">
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
                class="rounded-md border bg-muted/20 p-3"
              >
                <div class="text-xs text-muted-foreground">
                  {{ metric.label }}
                </div>
                <div class="mt-1 text-xl font-semibold">
                  {{ metric.value }}
                </div>
              </div>
            </div>

            <div class="rounded-md border bg-muted/20 p-3">
              <div class="text-xs text-muted-foreground">
                {{ t('account.posts.metrics.likeRate') }}
              </div>
              <div class="mt-1 text-xl font-semibold">
                {{
                  `${Math.round((selectedStats?.likeRate ?? 0) * 100)}%`
                }}
              </div>
              <div
                v-if="analyticsLoading"
                class="mt-1 text-xs text-muted-foreground"
              >
                {{ t('account.posts.loadingAnalytics') }}
              </div>
            </div>

            <Separator />

            <div class="space-y-2">
              <Label for="managed-post-content">
                {{ t('account.posts.form.content') }}
              </Label>
              <Textarea
                id="managed-post-content"
                v-model="editForm.content"
                rows="7"
              />
            </div>

            <div class="grid gap-3 sm:grid-cols-2">
              <div class="space-y-2">
                <Label>{{ t('account.posts.form.visibility') }}</Label>
                <Select v-model="editForm.visibility">
                  <SelectTrigger>
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

              <div class="space-y-2">
                <Label>{{ t('account.posts.form.language') }}</Label>
                <Select v-model="editForm.language">
                  <SelectTrigger>
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

            <div class="space-y-2">
              <Label for="managed-post-location">
                {{ t('account.posts.form.location') }}
              </Label>
              <Input
                id="managed-post-location"
                v-model="editForm.location"
                :placeholder="t('post.composer.locationPlaceholder')"
              />
            </div>

            <div class="space-y-2">
              <Label for="managed-post-tags">
                {{ t('account.posts.form.tags') }}
              </Label>
              <Input
                id="managed-post-tags"
                v-model="editForm.tags"
                :placeholder="t('account.posts.form.tagsPlaceholder')"
              />
            </div>

            <div class="flex flex-wrap justify-between gap-2">
              <Button
                variant="outline"
                class="gap-2"
                @click="openSelectedPost(selectedPost)"
              >
                <Eye class="h-4 w-4" />
                {{ t('account.posts.open') }}
              </Button>
              <div class="flex flex-wrap gap-2">
                <Button
                  variant="destructive"
                  class="gap-2"
                  @click="askDelete(selectedPost)"
                >
                  <Trash2 class="h-4 w-4" />
                  {{ t('common.delete') }}
                </Button>
                <Button
                  class="gap-2"
                  :disabled="saving"
                  @click="saveSelectedPost"
                >
                  <Pencil class="h-4 w-4" />
                  {{
                    saving
                      ? t('common.processing')
                      : t('account.posts.save')
                  }}
                </Button>
              </div>
            </div>
          </div>
        </CardContent>
      </Card>
    </div>

    <Dialog
      :open="deleteDialogOpen"
      @update:open="deleteDialogOpen = $event"
    >
      <DialogContent class="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{{ t('post.delete.title') }}</DialogTitle>
          <DialogDescription>
            {{ t('post.delete.description') }}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button
            variant="outline"
            @click="deleteDialogOpen = false"
          >
            {{ t('common.cancel') }}
          </Button>
          <Button
            variant="destructive"
            :disabled="deleting"
            @click="confirmDelete"
          >
            {{
              deleting ? t('common.processing') : t('common.delete')
            }}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  </div>
</template>
