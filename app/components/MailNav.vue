<script lang="ts" setup>
import { Icon } from '@iconify/vue';
import { cn } from '@/lib/utils';
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger
} from '@/components/ui/tooltip';

export interface LinkProp {
  value: string;
  title: string;
  label?: string;
  icon: string;
  variant: 'default' | 'ghost';
}

defineProps<{
  isCollapsed: boolean;
  links: LinkProp[];
}>();

const emit = defineEmits<{
  (e: 'nav-click', value: string): void;
}>();

function handleClick(value: string) {
  emit('nav-click', value);
}
</script>

<template>
  <div
    :data-collapsed="isCollapsed"
    class="flex h-full flex-col gap-1 bg-muted/20 py-3"
  >
    <nav class="grid gap-0.5 px-2">
      <template v-for="(link, index) of links">
        <Tooltip
          v-if="isCollapsed"
          :key="`collapsed-${index}`"
          :delay-duration="0"
        >
          <TooltipTrigger as-child>
            <button
              type="button"
              :class="
                cn(
                  'group/nav relative flex h-9 w-9 items-center justify-center rounded-md text-muted-foreground transition-colors',
                  link.variant === 'default'
                    ? 'bg-accent text-accent-foreground'
                    : 'hover:bg-accent/50 hover:text-foreground'
                )
              "
              @click="handleClick(link.value)"
            >
              <span
                v-if="link.variant === 'default'"
                class="absolute inset-y-1.5 left-0 w-0.5 rounded-full bg-primary"
                aria-hidden="true"
              />
              <Icon :icon="link.icon" class="size-4" />
              <span class="sr-only">{{ link.title }}</span>
            </button>
          </TooltipTrigger>
          <TooltipContent
            side="right"
            class="flex items-center gap-3"
          >
            {{ link.title }}
            <span
              v-if="link.label"
              class="text-muted-foreground"
            >
              {{ link.label }}
            </span>
          </TooltipContent>
        </Tooltip>

        <button
          v-else
          :key="`expanded-${index}`"
          type="button"
          :class="
            cn(
              'group/nav relative flex h-8 w-full items-center gap-2 rounded-md px-2 text-left text-sm transition-colors',
              link.variant === 'default'
                ? 'bg-accent text-accent-foreground'
                : 'text-muted-foreground hover:bg-accent/50 hover:text-foreground'
            )
          "
          @click="handleClick(link.value)"
        >
          <span
            v-if="link.variant === 'default'"
            class="absolute inset-y-1.5 left-0 w-0.5 rounded-full bg-primary"
            aria-hidden="true"
          />
          <Icon :icon="link.icon" class="size-4 shrink-0" />
          <span
            class="min-w-0 flex-1 truncate"
            :class="link.variant === 'default' ? 'font-medium text-foreground' : ''"
          >
            {{ link.title }}
          </span>
          <span
            v-if="link.label"
            class="ml-auto inline-flex h-4 min-w-[16px] items-center justify-center rounded-full px-1 text-[10px] font-medium tabular-nums"
            :class="
              link.variant === 'default'
                ? 'bg-primary text-primary-foreground'
                : 'bg-muted text-muted-foreground'
            "
          >
            {{ link.label }}
          </span>
        </button>
      </template>
    </nav>
  </div>
</template>
