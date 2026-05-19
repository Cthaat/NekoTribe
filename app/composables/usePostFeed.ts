import type { PostPageVM, PostVM } from '@/types/posts';

interface UsePostFeedOptions {
  debugName?: string;
  pageSize?: number;
  loadPage: (
    page: number,
    pageSize: number
  ) => Promise<PostPageVM>;
}

interface PostFeedState {
  page: number;
  pageSize: number;
  posts: PostVM[];
  loading: boolean;
  error: string | null;
  total: number;
  totalPages: number;
  refresh: () => Promise<void>;
  removePost: (postId: number) => void;
  patchPost: (
    postId: number,
    updater: (post: PostVM) => PostVM
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

export function usePostFeed(
  options: UsePostFeedOptions
): PostFeedState {
  const debugName = options.debugName ?? 'default';

  const state = reactive<PostFeedState>({
    page: 1,
    pageSize: options.pageSize ?? 15,
    posts: [],
    loading: false,
    error: null,
    total: 0,
    totalPages: 1,
    async refresh(this: PostFeedState): Promise<void> {
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
        this.loading = false;
      }
    },
    removePost(this: PostFeedState, postId: number): void {
      this.posts = this.posts.filter(
        (post: PostVM) => post.id !== postId
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
      this: PostFeedState,
      postId: number,
      updater: (post: PostVM) => PostVM
    ): void {
      const index = this.posts.findIndex(
        (post: PostVM) => post.id === postId
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

  return state;
}
