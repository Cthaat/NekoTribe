<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, shallowRef, watch } from 'vue';
import { v2ListPostLikers } from '@/api/v2/posts';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog';
import { authQueueFor } from '@/services/auth-request-queue';
import type { V2PublicUser } from '@/types/v2';

const props = defineProps<{ postId: number }>();
const { t } = useAppLocale();
const localePath = useLocalePath();
const app = useNuxtApp();
const auth = authQueueFor(app);
const open = ref(false);
const users = shallowRef<V2PublicUser[]>([]);
const page = ref(1);
const next = ref(false);
const loading = ref(false);
const failed = ref(false);
let current: AbortController | undefined;
let unsubscribe: (() => void) | undefined;

function clear() {
  current?.abort();
  current = undefined;
  users.value = [];
  next.value = false;
  loading.value = false;
  failed.value = false;
}

async function load(target: number) {
  if (!open.value || loading.value || auth.isIdentityChanging) return;
  clear();
  const request = new AbortController();
  const revision = auth.revision;
  const postId = props.postId;
  const valid = () => current === request && open.value && revision === auth.revision && postId === props.postId;
  current = request;
  page.value = target;
  loading.value = true;
  try {
    const result = await app.runWithContext(() => v2ListPostLikers(postId, target, request.signal));
    if (!valid()) return;
    users.value = result.items;
    next.value = result.meta?.has_next === true;
  } catch {
    if (valid()) failed.value = true;
  } finally {
    if (valid()) loading.value = false;
  }
}

watch(open, value => {
  if (value) void load(1);
  else clear();
}, { flush: 'sync' });
onMounted(() => {
  unsubscribe = auth.subscribe(() => { open.value = false; clear(); });
});
onBeforeUnmount(() => { unsubscribe?.(); clear(); });
</script>

<template>
  <Dialog v-model:open="open">
    <DialogTrigger as-child>
      <Button variant="ghost" size="sm" class="mt-2">{{ t('post.likers.title') }}</Button>
    </DialogTrigger>
    <DialogContent class="max-h-[80vh] overflow-y-auto" :aria-describedby="undefined">
      <DialogHeader><DialogTitle>{{ t('post.likers.title') }}</DialogTitle></DialogHeader>
      <p v-if="loading" role="status">{{ t('post.likers.loading') }}</p>
      <p v-else-if="failed" role="status">{{ t('post.likers.failed') }}</p>
      <p v-else-if="!users.length">{{ t('post.likers.empty') }}</p>
      <ul v-else class="divide-y">
        <li v-for="user in users" :key="user.user_id">
          <NuxtLink class="block break-all py-2 hover:underline" :to="localePath(`/user/${user.user_id}/profile`)" @click="open = false">
            {{ user.display_name || user.username }} <span class="text-muted-foreground">@{{ user.username }}</span>
          </NuxtLink>
        </li>
      </ul>
      <div v-if="!loading" class="flex flex-wrap gap-2">
        <Button v-if="failed" variant="outline" @click="load(page)">{{ t('post.likers.retry') }}</Button>
        <Button v-if="page > 1" variant="outline" @click="load(page - 1)">{{ t('post.likers.previous') }}</Button>
        <Button v-if="next" variant="outline" @click="load(page + 1)">{{ t('post.likers.next') }}</Button>
      </div>
    </DialogContent>
  </Dialog>
</template>
