<script setup lang="ts">
import { Icon } from '@iconify/vue';
import { Button } from '@/components/ui/button';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';

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
    <DropdownMenuContent align="end">
      <DropdownMenuItem
        v-for="option in localeOptions"
        :key="option.code"
        :data-active="option.code === locale"
        @select="() => setAppLocale(option.code)"
      >
        {{ option.name }}
      </DropdownMenuItem>
    </DropdownMenuContent>
  </DropdownMenu>
</template>
