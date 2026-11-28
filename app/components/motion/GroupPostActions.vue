<script setup lang="ts">
import { Bookmark, BookmarkCheck, Repeat } from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogTitle, DialogDescription } from '@/components/ui/dialog';
import { groupBookmarkKey, toggleGroupBookmark } from '@/utils/group-bookmark';
import { getGroup } from '@/services/groups';
import { v2CreatePost } from '@/services/posts';
import { authQueueFor } from '@/services/auth-request-queue';

const props = defineProps<{ groupId: number; postId: number; actor: number }>();
const { t } = useAppLocale();
const localePath = useLocalePath();
const auth = authQueueFor(useNuxtApp());
const key = computed(() => groupBookmarkKey(props.actor, props.groupId, props.postId));
const marks = useState<Record<string, boolean>>('group-local-bookmarks', () => ({}));
function sync() {
  try { marks.value[key.value] = localStorage.getItem(key.value) === '1'; }
  catch { marks.value[key.value] = false; }
}
function storage(event: StorageEvent) { if (!event.key || event.key === key.value) sync(); }
onMounted(() => { sync(); window.addEventListener('storage', storage); });
onBeforeUnmount(() => window.removeEventListener('storage', storage));
function bookmark() {
  try { toggleGroupBookmark(marks.value, key.value, () => localStorage); } catch {
    toast.error(t('post.feedback.bookmarkFailed'));
  }
}
const url = ref('');
const pending = ref(false);
let disposed = false;
onBeforeUnmount(() => { disposed = true; });
async function share(confirm: boolean) {
  if (pending.value || auth.isIdentityChanging || (confirm && !url.value)) return;
  const revision = auth.revision;
  const current = () => !disposed && auth.revision === revision;
  pending.value = true;
  try {
    if (confirm) {
      await v2CreatePost({ content: url.value, visibility: 'public' });
      if (current()) { url.value = ''; toast.success(t('post.feedback.retweeted')); }
    } else {
      const group = await getGroup(props.groupId);
      if (!group.slug) throw new Error('Missing group slug');
      if (current()) url.value = new URL(localePath(`/groups/${encodeURIComponent(group.slug)}/posts/${props.postId}`), location.origin).href;
    }
  } catch { if (current()) toast.error(t('post.feedback.retweetFailed')); }
  finally { pending.value = false; }
}
</script>

<template>
  <Button variant="ghost" size="sm" :aria-pressed="!!marks[key]" :title="t('groups.posts.localBookmark')" @click.stop="bookmark">
    <component :is="marks[key] ? BookmarkCheck : Bookmark" class="size-4" /><span class="text-xs">{{ t('groups.posts.localBookmark') }}</span>
  </Button>
  <Button variant="ghost" size="icon" :aria-label="t('post.retweet.submit')" :disabled="pending" @click.stop="share(false)"><Repeat class="w3-repost size-4" /></Button>
  <Dialog :open="!!url" @update:open="open => { if (!open && !pending) url = '' }">
    <DialogContent>
      <DialogTitle>{{ t('post.retweet.title') }}</DialogTitle>
      <DialogDescription>{{ t('groups.posts.linkPreview') }}</DialogDescription>
      <p class="break-all rounded-xl bg-secondary p-3 text-sm">{{ url }}</p>
      <div class="flex justify-end gap-2">
        <Button variant="ghost" :disabled="pending" @click="url = ''">{{ t('common.cancel') }}</Button>
        <Button :disabled="pending" @click="share(true)">{{ t('post.retweet.submit') }}</Button>
      </div>
    </DialogContent>
  </Dialog>
</template>
