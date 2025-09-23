<script setup lang="ts">
// 外观设置页面
// - 主题（明亮/深色/跟随系统）
// - 语言（中/英）
// - 字体大小（小/正常/大）
// - 紧凑模式开关
//
// 数值写入 Pinia 的 preference store，客户端插件会同步到 <html> 的 class/data 属性，
// 全局 CSS 读取后实现全站即时生效。
// 引入计算属性工具
import { computed } from 'vue';
// 引入国际化钩子
import { useI18n } from 'vue-i18n';
// 引入偏好状态仓库（存储主题/语言/字号/紧凑模式）
import { usePreferenceStore } from '@/stores/user';
// 引入分隔线组件
import { Separator } from '@/components/ui/separator';
// 引入卡片组件
import { Card, CardContent } from '@/components/ui/card';
// 引入按钮组件
import { Button } from '@/components/ui/button';
// 引入颜色模式图标组件（纯展示）
import ColorModeIcon from '@/components/ColorModeIcon.vue';

// 取出偏好仓库实例
const pref = usePreferenceStore();
// 取出 i18n 实例（locale 用于切换语言）
const { locale, t } = useI18n();

// 主题模式绑定：读写 store 中的 theme_mode
const theme = computed({
  // 读取当前主题
  get: () => pref.preferences.theme_mode,
  // 写入并触发插件同步到 DOM
  set: v => pref.updatePreference('theme_mode', v)
});

// 紧凑模式绑定：切换后 <html> 会添加/移除 .compact
const compact = computed({
  // 读取当前紧凑模式
  get: () => pref.preferences.compact_mode,
  // 写入并触发插件同步到 DOM
  set: v => pref.updatePreference('compact_mode', v)
});

// 字号绑定：会写入 <html data-font-size>
const fontSize = computed({
  // 读取当前字号
  get: () => pref.preferences.font_size,
  // 写入并触发插件同步到 DOM
  set: v => pref.updatePreference('font_size', v)
});

// 语言绑定：同时更新 i18n 的 locale
const lang = computed({
  // 读取当前语言
  get: () => pref.preferences.language,
  // 写入 store 并更新 vue-i18n 的 locale
  set: v => {
    pref.updatePreference('language', v);
    locale.value = v as any;
  }
});
</script>

<template>
  <!-- 外层卡片容器，提供面板式视觉 -->
  <Card>
    <!-- 卡片内容区域 -->
    <CardContent>
      <!-- 页面主体：桌面端使用内边距更大的容器 -->
      <div class="hidden space-y-6 p-10 pb-16 md:block">
        <!-- 标题与描述容器 -->
        <div class="space-y-0.5">
          <!-- 页面主标题：外观设置 -->
          <h2 class="text-2xl font-bold tracking-tight">
            <!-- 国际化文案：标题 -->
            {{ $t('account.appearance.title') }}
          </h2>
          <!-- 页面副标题/描述 -->
          <p class="text-muted-foreground">
            <!-- 国际化文案：描述 -->
            {{ $t('account.appearance.description') }}
          </p>
        </div>
        <!-- 分隔线，用于分组 -->
        <Separator class="my-6" />

        <!-- 内容网格：每个区块放一组设置 -->
        <div class="grid gap-6">
          <!-- 主题模式区块（按钮内容可后续补充） -->
          <div class="space-y-2">
            <!-- 小标题与图标 -->
            <div class="flex items-center gap-2">
              <ColorModeIcon />
              <div class="font-medium">
                {{ $t('account.appearance.theme') }}
              </div>
            </div>
            <!-- 主题选择按钮三连：Light / Dark / System -->
            <div class="flex flex-wrap gap-2">
              <!-- Light 按钮：选中时使用 default 样式 -->
              <Button
                :variant="
                  theme === 'light' ? 'default' : 'outline'
                "
                @click="theme = 'light'"
                >{{
                  $t('account.appearance.themeLight')
                }}</Button
              >
              <!-- Dark 按钮 -->
              <Button
                :variant="
                  theme === 'dark' ? 'default' : 'outline'
                "
                @click="theme = 'dark'"
                >{{
                  $t('account.appearance.themeDark')
                }}</Button
              >
              <!-- System 按钮：跟随系统 -->
              <Button
                :variant="
                  theme === 'system' ? 'default' : 'outline'
                "
                @click="theme = 'system'"
                >{{
                  $t('account.appearance.themeSystem')
                }}</Button
              >
            </div>
          </div>

          <!-- 语言切换区块 -->
          <div class="space-y-2">
            <!-- 小标题：语言 -->
            <div class="font-medium">
              {{ $t('account.appearance.language') }}
            </div>
            <!-- 语言按钮组：中文 / English -->
            <div class="flex flex-wrap gap-2">
              <!-- 中文按钮：lang === 'cn' 时为选中态 -->
              <Button
                :variant="
                  lang === 'cn' ? 'default' : 'outline'
                "
                @click="lang = 'cn'"
                >中文</Button
              >
              <!-- English 按钮：lang === 'en' 时为选中态 -->
              <Button
                :variant="
                  lang === 'en' ? 'default' : 'outline'
                "
                @click="lang = 'en'"
                >English</Button
              >
            </div>
          </div>

          <!-- 字体大小区块 -->
          <div class="space-y-2">
            <!-- 小标题：字号 -->
            <div class="font-medium">
              {{ $t('account.appearance.fontSize') }}
            </div>
            <!-- 字号按钮组：small / normal / large -->
            <div class="flex flex-wrap gap-2">
              <!-- small 按钮 -->
              <Button
                :variant="
                  fontSize === 'small'
                    ? 'default'
                    : 'outline'
                "
                @click="fontSize = 'small'"
                >{{
                  $t('account.appearance.fontSmall')
                }}</Button
              >
              <!-- normal 按钮 -->
              <Button
                :variant="
                  fontSize === 'normal'
                    ? 'default'
                    : 'outline'
                "
                @click="fontSize = 'normal'"
                >{{
                  $t('account.appearance.fontNormal')
                }}</Button
              >
              <!-- large 按钮 -->
              <Button
                :variant="
                  fontSize === 'large'
                    ? 'default'
                    : 'outline'
                "
                @click="fontSize = 'large'"
                >{{
                  $t('account.appearance.fontLarge')
                }}</Button
              >
            </div>
          </div>

          <!-- 紧凑模式区块 -->
          <div class="space-y-2">
            <!-- 小标题：紧凑模式 -->
            <div class="font-medium">
              {{ $t('account.appearance.compactMode') }}
            </div>
            <!-- 紧凑模式按钮组：开 / 关 -->
            <div class="flex flex-wrap gap-2">
              <!-- 开：compact === true -->
              <Button
                :variant="compact ? 'default' : 'outline'"
                @click="compact = true"
                >{{
                  $t('account.appearance.compactOn')
                }}</Button
              >
              <!-- 关：compact === false -->
              <Button
                :variant="!compact ? 'default' : 'outline'"
                @click="compact = false"
                >{{
                  $t('account.appearance.compactOff')
                }}</Button
              >
            </div>
          </div>
        </div>
      </div>
    </CardContent>
  </Card>
</template>
