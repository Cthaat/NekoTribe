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
  readonly totalPages: number;
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
    get totalPages() {
      return Math.max(
        1,
        Math.ceil(state.total / state.pageSize)
      );
    },
    async refresh(): Promise<void> {
      state.loading = true;
      state.error = null;

      logPostFeed(debugName, 'refresh:start', {
        page: state.page,
        pageSize: state.pageSize
      });

      try {
        const result = await options.loadPage(
          state.page,
          state.pageSize
        );
        state.posts = result.items;
        state.total = result.total;

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
        state.error = message;
        state.posts = [];
        state.total = 0;

        console.error(
          `[usePostFeed:${debugName}] refresh:error`,
          errorDetails
        );
      } finally {
        state.loading = false;
      }
    },
    removePost(postId: number): void {
      state.posts = state.posts.filter(
        post => post.id !== postId
      );
      state.total = Math.max(state.total - 1, 0);
      logPostFeed(debugName, 'remove', {
        postId,
        remaining: state.posts.length
      });
    },
    patchPost(
      postId: number,
      updater: (post: PostVM) => PostVM
    ): void {
      const index = state.posts.findIndex(
        post => post.id === postId
      );
      if (index === -1) {
        console.warn(
          `[usePostFeed:${debugName}] patch:missing-post`,
          { postId }
        );
        return;
      }

      const currentPost = state.posts[index];
      if (!currentPost) return;
      state.posts[index] = updater(currentPost);
      logPostFeed(debugName, 'patch', { postId });
    }
  });

  return state;
}
