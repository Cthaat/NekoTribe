<script setup lang="ts">
import { computed, ref, useId, watch } from 'vue';
import { useEventListener } from '@vueuse/core';
import { ArrowUpRight, Search } from 'lucide-vue-next';
import { Dialog, DialogContent, DialogDescription, DialogTitle } from '@/components/ui/dialog';
import { useCommandChatSearch } from '@/composables/useCommandChatSearch';
import { authQueueFor } from '@/services/auth-request-queue';
import { usePreferenceStore } from '@/stores/user';
import { readAppShortcut } from '@/utils/app-shortcuts';

interface Command {
  id: string;
  label: string;
  run: () => void;
}

const open = defineModel<boolean>('open', { required: true });
const { t } = useAppLocale();
const route = useRoute();
const localePath = useLocalePath();
const colorMode = useColorMode();
const preferences = usePreferenceStore();
const auth = authQueueFor(useNuxtApp());
const chatSearch = useCommandChatSearch();
const field = ref<HTMLInputElement>();
const query = ref('');
const selected = ref(0);
const listId = useId();
let returnFocus: HTMLElement | null = null;

function searchChat(keyword: string) {
  if (!preferences.isLoggedIn || auth.isIdentityChanging) {
    void navigateTo(localePath('/chat'));
    return;
  }
  chatSearch.value = { query: keyword, owner: auth.revision };
  if (route.path !== localePath('/chat')) void navigateTo(localePath('/chat'));
}

function link(id: string, path: string, params?: Record<string, string>): Command {
  return {
    id,
    label: t(`commandPalette.${id}`),
    run: () => { void navigateTo(localePath({ path, query: params })); }
  };
}

const commands = computed(() => {
  const keyword = query.value.trim();
  const navigation = [
    link('compose', '/meow'),
    link('discover', '/discover'),
    link('groups', '/groups/discover'),
    link('openChat', '/chat'),
    link('writing', '/ai/writing'),
    link('knowledge', '/ai/knowledge'),
    {
      id: 'theme',
      label: t('commandPalette.theme'),
      run: () => {
        const theme = document.documentElement.classList.contains('dark') ? 'light' : 'dark';
        preferences.updatePreference('theme_mode', theme);
        colorMode.preference = theme;
      }
    },
    {
      id: 'glass',
      label: t('commandPalette.glass'),
      run: () => preferences.updatePreference('glass_intensity',
        preferences.preferences.glass_intensity === 'subtle' ? 'standard' : 'subtle')
    }
  ];
  if (!keyword) return navigation;
  const search = [
    link('posts', `/tweet/search/${encodeURIComponent(keyword)}`),
    ...(keyword.length >= 2 ? [link('people', '/discover', { people: keyword })] : []),
    link('findGroups', '/groups/discover', { q: keyword }),
    { id: 'messages', label: t('commandPalette.messages'), run: () => searchChat(keyword) }
  ];
  return [...search, ...navigation.filter(item => item.label.toLowerCase().includes(keyword.toLowerCase()))];
});

function optionId(item: Command) {
  return `${listId}-${item.id}`;
}

const activeOption = computed(() => commands.value[selected.value]);
watch(query, () => { selected.value = 0; }, { flush: 'sync' });
watch(() => route.path, () => { open.value = false; });
watch(open, value => {
  if (value) {
    returnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  } else {
    query.value = '';
    selected.value = 0;
  }
}, { flush: 'sync' });

useEventListener('keydown', event => {
  if (readAppShortcut(event) !== 'palette') return;
  const activeModal = '[role="dialog"][data-state="open"]:not([data-slot="popover-content"]), [role="alertdialog"][data-state="open"]';
  if (!open.value && document.querySelector(activeModal)) return;
  event.preventDefault();
  open.value = !open.value;
});

function execute(item: Command) {
  open.value = false;
  item.run();
}

function navigateOptions(event: KeyboardEvent) {
  if (event.isComposing || event.defaultPrevented) return;
  if (event.key === 'Enter' && activeOption.value) {
    event.preventDefault();
    execute(activeOption.value);
    return;
  }
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
  event.preventDefault();
  const step = event.key === 'ArrowDown' ? 1 : -1;
  selected.value = (selected.value + step + commands.value.length) % commands.value.length;
  const option = activeOption.value;
  if (option) document.getElementById(optionId(option))?.scrollIntoView({ block: 'nearest' });
}

function restoreFocus(event: Event) {
  event.preventDefault();
  returnFocus?.focus({ preventScroll: true });
  returnFocus = null;
}
</script>

<template>
  <Dialog v-model:open="open">
    <DialogContent
      class="gap-2 sm:max-w-xl"
      @open-auto-focus.prevent="field?.focus()"
      @close-auto-focus="restoreFocus"
    >
      <DialogTitle>{{ t('commandPalette.title') }}</DialogTitle>
      <DialogDescription class="sr-only">{{ t('commandPalette.instructions') }}</DialogDescription>
      <div class="relative">
        <Search aria-hidden="true" class="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
        <input
          ref="field"
          v-model="query"
          type="text"
          role="combobox"
          aria-autocomplete="list"
          aria-expanded="true"
          :aria-label="t('commandPalette.placeholder')"
          :aria-controls="listId"
          :aria-activedescendant="activeOption ? optionId(activeOption) : undefined"
          :placeholder="t('commandPalette.placeholder')"
          maxlength="100"
          autocomplete="off"
          class="h-11 w-full rounded-full border border-input bg-background/65 pl-9 pr-4 focus-visible:outline-2 focus-visible:outline-ring"
          @keydown="navigateOptions"
        >
      </div>
      <ul :id="listId" role="listbox" :aria-label="t('commandPalette.title')" class="max-h-[50dvh] space-y-1 overflow-y-auto">
        <li
          v-for="(item, index) in commands"
          :id="optionId(item)"
          :key="item.id"
          role="option"
          :aria-selected="selected === index"
          class="flex cursor-pointer items-center justify-between gap-3 rounded-xl px-3 py-2.5 text-sm"
          :class="selected === index ? 'bg-accent text-accent-foreground' : undefined"
          @mousedown.prevent
          @click="execute(item)"
          @pointermove="selected = index"
        >
          {{ item.label }}
          <ArrowUpRight aria-hidden="true" class="size-3.5 shrink-0 opacity-60" />
        </li>
      </ul>
    </DialogContent>
  </Dialog>
</template>
