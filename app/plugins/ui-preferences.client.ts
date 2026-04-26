import { usePreferenceStore } from '@/stores/user';

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
  // 不能在插件里直接调用 useI18n（需处于组件 setup 上下文），
  // 这里通过 NuxtApp 注入的 $i18n 进行交互，兼容 @nuxtjs/i18n 或手动安装的 vue-i18n。
  const { $i18n } = useNuxtApp() as any;

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

  /**
   * 同步多语言：当偏好语言变化时，尽量更新 i18n 的 locale，并同步 <html lang>
   * 兼容几种常见形态：
   * - $i18n.setLocale(lang)
   * - $i18n.locale.value = lang
   * - $i18n.global.locale.value = lang
   * - $i18n.locale = lang（字符串）
   */
  const applyLanguage = () => {
    const lang = pref.preferences.language as
      | string
      | undefined;
    if (!lang) return;

    try {
      // 读取当前语言
      let current: string | undefined;
      if ($i18n?.locale?.value !== undefined)
        current = $i18n.locale.value;
      else if ($i18n?.global?.locale?.value !== undefined)
        current = $i18n.global.locale.value;
      else if (typeof $i18n?.locale === 'string')
        current = $i18n.locale;

      if (current !== lang) {
        if (typeof $i18n?.setLocale === 'function') {
          // 部分 i18n 集成提供的异步设置方法
          $i18n.setLocale(lang);
        } else if ($i18n?.locale?.value !== undefined) {
          $i18n.locale.value = lang;
        } else if (
          $i18n?.global?.locale?.value !== undefined
        ) {
          $i18n.global.locale.value = lang;
        } else if (typeof $i18n?.locale === 'string') {
          $i18n.locale = lang;
        }
      }
    } catch {
      // 忽略可能的环境差异错误
    }

    // 无论 i18n 是否可用，都同步到 <html lang>
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
