<script setup lang="ts">
import { Icon } from '@iconify/vue';
import { Button } from '@/components/ui/button';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
import { Check } from 'lucide-vue-next';

const { t, locale, localeOptions, setAppLocale } =
  useAppLocale();
</script>

<template>
  <DropdownMenu>
    <DropdownMenuTrigger as-child>
      <Button variant="ghost" size="icon">
        <Icon
          icon="lucide:languages"
          class="h-[1.2rem] w-[1.2rem]"
        />
        <span class="sr-only">{{
          t('preferences.language.toggle')
        }}</span>
      </Button>
    </DropdownMenuTrigger>
    <DropdownMenuContent align="end" class="w-40">
      <DropdownMenuItem
        v-for="option in localeOptions"
        :key="option.code"
        :data-active="option.code === locale"
        class="flex items-center justify-between"
        @select="() => setAppLocale(option.code)"
      >
        <span>{{ option.name }}</span>
        <Check
          v-if="option.code === locale"
          class="h-4 w-4 text-primary"
        />
      </DropdownMenuItem>
    </DropdownMenuContent>
  </DropdownMenu>
</template>
