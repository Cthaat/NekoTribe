<script setup lang="ts">
import { useElementSize } from '@vueuse/core';
import { Check } from 'lucide-vue-next';
import { v2FollowUser, v2UnfollowUser } from '@/services/users';
import { authQueueFor } from '@/services/auth-request-queue';
import { toast } from 'vue-sonner';

const props = defineProps<{ authorId: number; relation?: string }>();
const { t } = useAppLocale();
const viewer = usePreferenceStore();
const auth = authQueueFor(useNuxtApp());
const key = computed(() => `${viewer.preferences.user.id}:${props.authorId}`);
const updates = useState<Record<string, string>>('post-follow-relations', () => ({}));
const pending = useState<Record<string, boolean>>('post-follow-pending', () => ({}));
watch(() => props.relation, value => {
  if (value && !pending.value[key.value]) delete updates.value[key.value];
});
const relation = computed(() => updates.value[key.value] ?? props.relation);
const following = computed(() => ['following', 'mutual_follow'].includes(relation.value ?? ''));
const allowed = computed(() => viewer.isLoggedIn && viewer.preferences.user.id !== props.authorId &&
  !!relation.value && !['self', 'blocked_by', 'blocking'].includes(relation.value));
async function toggle() {
  const who = key.value, previous = relation.value, revision = auth.revision;
  if (!allowed.value || !previous || pending.value[who] || auth.isIdentityChanging) return;
  const remove = following.value;
  updates.value[who] = remove ? 'none' : 'following';
  pending.value[who] = true;
  try {
    const result = await (remove ? v2UnfollowUser(props.authorId) : v2FollowUser(props.authorId));
    if (revision === auth.revision) updates.value[who] = result.relationship;
  } catch {
    if (revision === auth.revision) {
      updates.value[who] = previous;
      toast.error(t('account.follow.failed'));
    }
  } finally {
    delete pending.value[who];
    if (revision !== auth.revision) delete updates.value[who];
  }
}
const offLabel = ref<HTMLElement>();
const onLabel = ref<HTMLElement>();
const off = useElementSize(offLabel), on = useElementSize(onLabel);
const width = computed(() => (following.value ? on.width.value : off.width.value) || undefined);
</script>

<template>
  <button v-if="allowed" type="button" class="w3-follow relative inline-flex items-center rounded-full bg-secondary px-3 py-1 text-xs font-medium"
    :aria-label="t(following ? 'discover.following' : 'discover.follow')" :aria-pressed="following" :disabled="pending[key]" @click.stop="toggle">
    <span :style="{ width: width && width + 'px' }" class="w3-follow-width relative inline-flex items-center">
      <span ref="offLabel" aria-hidden="true" class="w-max whitespace-nowrap" :class="{ 'absolute invisible': following }">{{ t('discover.follow') }}</span>
      <span ref="onLabel" aria-hidden="true" class="inline-flex w-max items-center gap-1 whitespace-nowrap" :class="{ 'absolute invisible': !following }">
        <Check class="size-3" />{{ t('discover.following') }}
      </span>
    </span>
  </button>
</template>
