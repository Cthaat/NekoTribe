<script setup lang="ts">
import { computed, watch } from 'vue';
import { Bell, Home, MessageCircle, User, Users } from 'lucide-vue-next';
import { useScrollDirection } from '@/composables/useScrollDirection';
import { usePreferenceStore } from '@/stores/user';

const { t } = useAppLocale();
const localePath = useLocalePath();
const route = useRoute();
const preferences = usePreferenceStore();
const { isHidden, prefersReducedMotion, reset } = useScrollDirection({
  threshold: 48,
  hysteresis: 16
});
const condensed = computed(() => isHidden.value && !prefersReducedMotion.value);

watch(
  () => route.path,
  () => {
    reset();
  }
);

const userId = computed(() => preferences.preferences.user.id);
const signedIn = computed(() => preferences.isLoggedIn);

const items = computed(() => [
  {
    key: 'home',
    label: t('nav.main.home'),
    to: localePath('/'),
    icon: Home,
    match: (path: string) => path === localePath('/')
  },
  {
    key: 'groups',
    label: t('nav.main.groups'),
    to: localePath('/groups/discover'),
    icon: Users,
    match: (path: string) => path.includes('/groups')
  },
  {
    key: 'notifications',
    label: t('nav.main.notifications'),
    to: signedIn.value ? localePath(`/user/${userId.value}/notifications`) : localePath('/auth/login'),
    icon: Bell,
    match: (path: string) => path.includes('/notifications')
  },
  {
    key: 'chat',
    label: t('nav.main.chat'),
    to: localePath('/chat'),
    icon: MessageCircle,
    match: (path: string) => path.includes('/chat')
  },
  {
    key: 'profile',
    label: t('nav.main.me'),
    to: signedIn.value ? localePath(`/user/${userId.value}/profile`) : localePath('/account/overview'),
    icon: User,
    match: (path: string) => path.includes('/profile') || path.includes('/account')
  }
]);

const activeIndex = computed(() =>
  items.value.findIndex(item => item.match(route.path))
);
const { events, pressed, pillStyle, itemStyle } = useLiquidScrub(activeIndex, index => {
  const item = items.value[index];
  if (item) void navigateTo(item.to);
});
</script>

<template>
  <nav
    class="fixed inset-x-4 bottom-3 z-40 mx-auto flex h-[64px] max-w-[400px] origin-bottom items-center rounded-full p-1.5 liquid-glass-dock transition-[translate,scale] duration-220 ease-[var(--ease-spring)] focus-within:translate-y-0 focus-within:scale-100 motion-reduce:transition-none md:hidden"
    :class="condensed ? 'translate-y-1 scale-[0.96]' : 'translate-y-0 scale-100'"
    :data-condensed="condensed"
    :aria-label="t('nav.main.home')"
  >
    <div
      class="liquid-scrub relative grid h-full w-full items-center"
      :data-pressed="pressed"
      v-on="events"
      :style="{ gridTemplateColumns: `repeat(${items.length}, minmax(0, 1fr))` }"
    >
      <span
        v-if="activeIndex >= 0 || pressed"
        aria-hidden="true"
        class="liquid-glass-active-pill pointer-events-none absolute inset-y-0 left-0 rounded-full scrub-pill"
        :style="{
          width: `${100 / items.length}%`,
          ...pillStyle
        }"
      />
      <NuxtLink
        v-for="(item, index) in items"
        :key="item.key"
        :to="item.to"
        data-scrub-item
        :aria-current="index === activeIndex ? 'page' : undefined"
        :style="itemStyle(index)"
        class="pressable relative z-10 flex h-full min-w-0 flex-col items-center justify-center gap-0.5 rounded-full px-1 transition-colors"
        :class="
          index === activeIndex
            ? 'text-primary font-semibold'
            : 'text-muted-foreground hover:text-foreground'
        "
      >
        <component
          :is="item.icon"
          class="size-[19px]"
          :stroke-width="index === activeIndex ? 2.15 : 1.75"
        />
        <span class="max-w-full truncate text-[10px] leading-tight">
          {{ item.label }}
        </span>
      </NuxtLink>
    </div>
  </nav>
</template>
