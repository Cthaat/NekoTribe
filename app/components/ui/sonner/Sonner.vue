<script lang="ts" setup>
import { computed } from 'vue'
import { Toaster as Sonner, type ToasterProps } from 'vue-sonner'
import 'vue-sonner/style.css'

const props = defineProps<ToasterProps>()
const colorMode = useColorMode()
const resolvedTheme = computed<'light' | 'dark'>(() => {
  if (props.theme === 'light' || props.theme === 'dark') {
    return props.theme
  }
  return colorMode.value === 'dark' ? 'dark' : 'light'
})
</script>

<template>
  <Sonner
    class="toaster group"
    v-bind="props"
    :theme="resolvedTheme"
    :toast-options="{
      style: {
        borderRadius: '16px',
        boxShadow: '0 8px 24px rgba(0, 0, 0, 0.14)',
      },
      ...props.toastOptions,
    }"
    :style="{
      '--normal-bg': 'var(--card)',
      '--normal-text': 'var(--foreground)',
      '--normal-border': 'var(--divider)',
      '--info-bg': 'var(--card)',
      '--info-text': 'var(--foreground)',
      '--info-border': 'var(--divider)',
      '--success-bg': 'var(--card)',
      '--success-text': 'var(--foreground)',
      '--success-border': 'var(--divider)',
      '--warning-bg': 'var(--card)',
      '--warning-text': 'var(--foreground)',
      '--warning-border': 'var(--divider)',
      '--error-bg': 'var(--card)',
      '--error-text': 'var(--destructive)',
      '--error-border': 'var(--divider)',
      '--border-radius': '16px',
    }"
  />
</template>
