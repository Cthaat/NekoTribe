import { reactive } from 'vue';
import type { PageViewModel, PostVM } from '@/types/posts';

interface UsePostFeedOptions<T> {
  debugName?: string;
  pageSize?: number;
  loadPage: (
    page: number,
    pageSize: number
  ) => Promise<PageViewModel<T>>;
}

export interface PostFeedState<T = PostVM> {
  page: number;
  pageSize: number;
  posts: T[];
  loading: boolean;
  error: string | null;
  total: number;
  totalPages: number;
  refresh: () => Promise<void>;
  invalidate: () => void;
  removePost: (postId: number) => void;
  patchPost: (
    postId: number,
    updater: (post: T) => T
  ) => void;
}

interface SerializedFeedError {
  name?: string;
  message: string;
  statusCode?: number;
  statusMessage?: string;
  data?: unknown;
  stack?: string;
}

function toSerializable(value: unknown): unknown {
  if (
    value === null ||
    typeof value === 'string' ||
    typeof value === 'number' ||
    typeof value === 'boolean'
  ) {
    return value;
  }

  if (Array.isArray(value)) {
    return value.map(toSerializable);
  }

  if (typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(
        ([key, item]) => [key, toSerializable(item)]
      )
    );
  }

  return String(value);
}

function serializeFeedError(error: unknown): SerializedFeedError {
  const candidate = error as {
    name?: string;
    message?: string;
    statusCode?: number;
    statusMessage?: string;
    data?: unknown;
    response?: {
      status?: number;
      statusText?: string;
      _data?: unknown;
    };
    stack?: string;
  };

  return {
    name: candidate.name,
    message: candidate.message ?? String(error),
    statusCode:
      candidate.statusCode ?? candidate.response?.status,
    statusMessage:
      candidate.statusMessage ??
      candidate.response?.statusText,
    data: toSerializable(
      candidate.data ?? candidate.response?._data
    ),
    stack: candidate.stack
  };
}

function logPostFeed(
  debugName: string,
  message: string,
  payload?: Record<string, unknown>
): void {
  console.info(
    `[usePostFeed:${debugName}] ${message}`,
    payload ?? {}
  );
}

export function usePostFeed<T extends { id: number } = PostVM>(
  options: UsePostFeedOptions<T>
): PostFeedState<T> {
  const debugName = options.debugName ?? 'default';
  let request = 0;

  const state = reactive<PostFeedState<T>>({
    page: 1,
    pageSize: options.pageSize ?? 15,
    posts: [],
    loading: false,
    error: null,
    total: 0,
    totalPages: 1,
    invalidate(this: PostFeedState<T>): void {
      request++;
      this.posts = [];
      this.total = 0;
      this.totalPages = 1;
      this.loading = false;
      this.error = null;
    },
    async refresh(this: PostFeedState<T>): Promise<void> {
      const current = ++request;
      this.loading = true;
      this.error = null;

      logPostFeed(debugName, 'refresh:start', {
        page: this.page,
        pageSize: this.pageSize
      });

      try {
        const result = await options.loadPage(
          this.page,
          this.pageSize
        );
        if (current !== request) return;
        this.posts = result.items;
        this.total = result.total;
        this.totalPages = Math.max(
          1,
          Math.ceil(this.total / this.pageSize)
        );

        logPostFeed(debugName, 'refresh:success', {
          itemCount: result.items.length,
          total: result.total,
          page: result.page,
          pageSize: result.pageSize,
          hasNext: result.hasNext,
          firstIds: result.items
            .slice(0, 5)
            .map(post => post.id)
        });
      } catch (caught) {
        if (current !== request) return;
        const errorDetails = serializeFeedError(caught);
        const message =
          errorDetails.message || '加载推文失败';
        this.error = message;
        this.posts = [];
        this.total = 0;
        this.totalPages = 1;

        console.error(
          `[usePostFeed:${debugName}] refresh:error`,
          errorDetails
        );
      } finally {
        if (current === request) this.loading = false;
      }
    },
    removePost(this: PostFeedState<T>, postId: number): void {
      this.posts = this.posts.filter(
        post => post.id !== postId
      );
      this.total = Math.max(this.total - 1, 0);
      this.totalPages = Math.max(
        1,
        Math.ceil(this.total / this.pageSize)
      );
      logPostFeed(debugName, 'remove', {
        postId,
        remaining: this.posts.length
      });
    },
    patchPost(
      this: PostFeedState<T>,
      postId: number,
      updater: (post: T) => T
    ): void {
      const index = this.posts.findIndex(
        post => post.id === postId
      );
      if (index === -1) {
        console.warn(
          `[usePostFeed:${debugName}] patch:missing-post`,
          { postId }
        );
        return;
      }

      const currentPost = this.posts[index];
      if (!currentPost) return;
      this.posts[index] = updater(currentPost);
      logPostFeed(debugName, 'patch', { postId });
    }
  });

  return state as PostFeedState<T>;
}
