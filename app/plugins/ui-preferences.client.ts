import { usePreferenceStore } from '@/stores/user';
import {
  normalizeAppLocale,
  useAppLocaleController
} from '@/composables/useAppLocale';

/**
 * 客户端 UI 偏好同步插件
 *
 * 作用：
 * - 读取 Pinia 中的用户外观偏好（主题、字号、紧凑模式、语言）
 * - 将其同步到 <html> 上的 class 或 data-* 属性，配合全局 CSS 生效
 * - 监听偏好变化，实时更新，不需要刷新页面
 *
 * 注意：仅在客户端运行（process.server 时直接返回）
 */

export default defineNuxtPlugin(() => {
  if (process.server) return;
  const pref = usePreferenceStore();
  const { locale, setAppLocale } = useAppLocaleController();

  // html 根节点，用于挂载 class 与 data- 属性
  const html = document.documentElement;
  // 用于系统主题监听的匹配器（仅当选择“跟随系统”时开启监听）
  let mql: MediaQueryList | null = null;

  /**
   * 根据偏好应用主题（dark/light/system）
   * - dark: 强制添加 .dark
   * - light: 强制移除 .dark
   * - system: 依据操作系统偏好，并监听系统切换及时更新
   */
  const applyTheme = () => {
    const mode = pref.preferences.theme_mode;
    const useDark = () => html.classList.add('dark');
    const useLight = () => html.classList.remove('dark');

    // cleanup previous listener
    // 清除上一次添加的系统主题监听器，避免重复绑定
    if (mql) {
      try {
        mql.removeEventListener('change', onSystemChange);
      } catch {}
      mql = null;
    }

    function onSystemChange(e: MediaQueryListEvent) {
      e.matches ? useDark() : useLight();
    }

    if (mode === 'dark') useDark();
    else if (mode === 'light') useLight();
    else {
      mql = window.matchMedia(
        '(prefers-color-scheme: dark)'
      );
      mql.matches ? useDark() : useLight();
      try {
        mql.addEventListener('change', onSystemChange);
      } catch {}
    }
    // 额外记录 theme 到 data- 属性，便于需要时做基于数据属性的选择器
    html.dataset.theme = String(mode);
  };

  /**
   * 将字号偏好写入 data-font-size（small/normal/large）
   * 对应全局 CSS 中基于 data 属性的 font-size 映射
   */
  const applyFontSize = () => {
    html.dataset.fontSize = String(
      pref.preferences.font_size || 'normal'
    );
  };

  /**
   * 紧凑模式：在 <html> 上添加/移除 .compact 类
   * 全局 CSS 会在 .compact 作用域下收紧常见间距/内边距
   */
  const applyCompact = () => {
    if (pref.preferences.compact_mode)
      html.classList.add('compact');
    else html.classList.remove('compact');
  };

  const applyLanguage = () => {
    const lang = normalizeAppLocale(pref.preferences.language);
    if (locale.value !== lang) {
      void setAppLocale(lang);
    }
    html.setAttribute('lang', lang);
  };

  // initial apply
  applyTheme();
  applyFontSize();
  applyCompact();
  applyLanguage();

  // watch reactive store
  // 监控相关偏好变更，逐项应用，保证实时生效
  watch(
    () => [
      pref.preferences.theme_mode,
      pref.preferences.font_size,
      pref.preferences.compact_mode,
      pref.preferences.language
    ],
    () => {
      applyTheme();
      applyFontSize();
      applyCompact();
      applyLanguage();
    },
    { deep: false }
  );
});
