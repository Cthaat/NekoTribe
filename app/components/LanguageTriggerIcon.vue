<script setup lang="ts">
import { Icon } from '@iconify/vue';
import { Button } from '@/components/ui/button';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
import { usePreferenceStore } from '~/stores/user';
import { useI18n } from 'vue-i18n';
import { watch } from 'vue'; // ✨ 1. 导入 watch

const preferenceStore = usePreferenceStore();
const { locale, availableLocales } = useI18n();

// ✨ 2. 使用 watch 来处理持久化存储的副作用
//    这是更健壮的做法，因为它能响应任何来源的语言变化
watch(locale, newLocale => {
  // 当语言切换时（无论通过何种方式），更新我们的 Pinia store
  preferenceStore.updatePreference('language', newLocale);
});

// getLanguageName 函数保持不变，是正确的
const getLanguageName = (langCode: string): string => {
  switch (langCode) {
    case 'en':
      return 'English';
    case 'cn': // ✨ 注意: 你的语言文件 key 可能是 'cn' 而不是 'zh-CN'，请保持一致
      return '简体中文';
    default:
      return langCode;
  }
};
</script>

<template>
  <DropdownMenu>
    <DropdownMenuTrigger as-child>
      <Button variant="ghost" size="icon">
        <Icon
          icon="lucide:languages"
          class="h-[1.2rem] w-[1.2rem]"
        />
        <span class="sr-only">Toggle language</span>
      </Button>
    </DropdownMenuTrigger>
    <DropdownMenuContent align="end">
      <!-- 
        ✨ 3. 极大地简化了 DropdownMenuItem
        我们移除了所有的 @click 逻辑。
        现在，它只是一个容器，真正的交互由内部的 NuxtLink 完
        设置 `as-child` 可以让菜单项的样式和行为由 NuxtLink 接管。
      -->
      <DropdownMenuItem
        v-for="lang in availableLocales"
        :key="lang"
        as-child
      >
        <NuxtLink :to="$switchLocalePath(lang)">
          {{ getLanguageName(lang) }}
        </NuxtLink>
      </DropdownMenuItem>
    </DropdownMenuContent>
  </DropdownMenu>
</template>
