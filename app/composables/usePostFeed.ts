import type { V2PagedResult, V2Post } from '@/types/v2';

interface UsePostFeedOptions {
  pageSize?: number;
  loadPage: (
    page: number,
    pageSize: number
  ) => Promise<V2PagedResult<V2Post>>;
}

export function usePostFeed(
  options: UsePostFeedOptions
) {
  const page = ref(1);
  const pageSize = ref(options.pageSize ?? 15);
  const posts = ref<V2Post[]>([]);
  const loading = ref(false);
  const error = ref<string | null>(null);
  const total = ref(0);

  const totalPages = computed(() =>
    Math.max(1, Math.ceil(total.value / pageSize.value))
  );

  async function refresh(): Promise<void> {
    loading.value = true;
    error.value = null;

    try {
      const result = await options.loadPage(
        page.value,
        pageSize.value
      );
      posts.value = result.items;
      total.value = result.meta?.total || result.items.length;
    } catch (caught) {
      error.value =
        caught instanceof Error
          ? caught.message
          : '加载推文失败';
      posts.value = [];
      total.value = 0;
    } finally {
      loading.value = false;
    }
  }

  function removePost(postId: number): void {
    posts.value = posts.value.filter(
      post => post.post_id !== postId
    );
    total.value = Math.max(total.value - 1, 0);
  }

  function patchPost(
    postId: number,
    updater: (post: V2Post) => V2Post
  ): void {
    const index = posts.value.findIndex(
      post => post.post_id === postId
    );
    if (index === -1) return;
    posts.value[index] = updater(posts.value[index]);
  }

  return {
    page,
    pageSize,
    posts,
    loading,
    error,
    total,
    totalPages,
    refresh,
    removePost,
    patchPost
  };
}
