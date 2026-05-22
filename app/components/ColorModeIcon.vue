<script setup lang="ts">
import { Icon } from '@iconify/vue'
import { Button } from '@/components/ui/button'
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'
import { Check } from 'lucide-vue-next'

const colorMode = useColorMode()
const { t } = useAppLocale()

const modes = [
  { value: 'light', label: 'preferences.theme.light' },
  { value: 'dark', label: 'preferences.theme.dark' },
  { value: 'system', label: 'preferences.theme.system' }
] as const
</script>

<template>
  <DropdownMenu>
    <DropdownMenuTrigger as-child>
      <Button variant="ghost" size="icon" class="relative">
        <Icon icon="radix-icons:moon"
          class="h-[1.2rem] w-[1.2rem] rotate-0 scale-100 transition-all dark:-rotate-90 dark:scale-0" />
        <Icon icon="radix-icons:sun"
          class="absolute h-[1.2rem] w-[1.2rem] rotate-90 scale-0 transition-all dark:rotate-0 dark:scale-100" />
        <span class="sr-only">{{ t('preferences.theme.toggle') }}</span>
      </Button>
    </DropdownMenuTrigger>
    <DropdownMenuContent align="end" class="w-40">
      <DropdownMenuItem
        v-for="mode in modes"
        :key="mode.value"
        :data-active="colorMode.preference === mode.value"
        class="flex items-center justify-between"
        @click="colorMode.preference = mode.value"
      >
        <span>{{ t(mode.label) }}</span>
        <Check
          v-if="colorMode.preference === mode.value"
          class="h-4 w-4 text-primary"
        />
      </DropdownMenuItem>
    </DropdownMenuContent>
  </DropdownMenu>
</template>
