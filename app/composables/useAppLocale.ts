import { usePreferenceStore } from '@/stores/user';
import { computed, isRef } from 'vue';
import type { ComputedRef, Ref } from 'vue';

export type AppLocaleCode = 'en' | 'zh';
type TranslationParams = Record<string, string | number>;
type LocaleList = Array<string | LocaleEntry>;

interface LocaleEntry {
  code: string;
  name?: string;
}

interface I18nWithLocaleControls {
  locale: string | Ref<string>;
  locales?: LocaleList | Ref<LocaleList>;
  availableLocales?: string[];
  setLocale?: (
    locale: string
  ) => Promise<void> | void;
  t: (key: string, params?: TranslationParams) => string;
}

interface NuxtAppWithI18n {
  $i18n?: I18nWithLocaleControls;
}

export interface AppLocaleOption {
  code: AppLocaleCode;
  name: string;
}

export interface AppLocaleContext {
  t: (
    key: string,
    params?: TranslationParams
  ) => string;
  locale: ComputedRef<AppLocaleCode>;
  localeOptions: ComputedRef<AppLocaleOption[]>;
  setAppLocale: (locale: string) => Promise<void>;
}

export function normalizeAppLocale(
  locale?: string | null
): AppLocaleCode {
  if (locale === 'zh' || locale === 'cn' || locale?.startsWith('zh')) {
    return 'zh';
  }

  return 'en';
}

function readI18nLocale(
  i18n: I18nWithLocaleControls
): string {
  return isRef(i18n.locale)
    ? String(i18n.locale.value)
    : i18n.locale;
}

function writeI18nLocale(
  i18n: I18nWithLocaleControls,
  locale: AppLocaleCode
): void {
  if (isRef(i18n.locale)) {
    i18n.locale.value = locale;
    return;
  }

  i18n.locale = locale;
}

function readI18nLocales(
  i18n: I18nWithLocaleControls
): LocaleList {
  if (Array.isArray(i18n.locales)) {
    return i18n.locales;
  }

  if (isRef(i18n.locales)) {
    return i18n.locales.value;
  }

  return i18n.availableLocales ?? [];
}

function createAppLocaleContext(
  i18n: I18nWithLocaleControls
): AppLocaleContext {
  const preferenceStore = usePreferenceStore();

  const t = (
    key: string,
    params?: TranslationParams
  ): string => i18n.t(key, params);

  const locale = computed<AppLocaleCode>(() =>
    normalizeAppLocale(readI18nLocale(i18n))
  );

  const localeOptions = computed<AppLocaleOption[]>(() => {
    const rawLocales = readI18nLocales(i18n);
    if (!rawLocales?.length) {
      return [
        { code: 'en', name: 'English' },
        { code: 'zh', name: '简体中文' }
      ];
    }

    return rawLocales
      .map(localeItem => {
        if (typeof localeItem === 'string') {
          const code = normalizeAppLocale(localeItem);
          return {
            code,
            name:
              code === 'zh'
                ? t('preferences.language.zh')
                : t('preferences.language.en')
          };
        }

        const code = normalizeAppLocale(localeItem.code);
        return {
          code,
          name:
            localeItem.name ||
            (code === 'zh'
              ? t('preferences.language.zh')
              : t('preferences.language.en'))
        };
      })
      .filter(
        (item, index, list) =>
          list.findIndex(candidate => candidate.code === item.code) ===
          index
      );
  });

  async function setAppLocale(nextLocale: string): Promise<void> {
    const normalizedLocale = normalizeAppLocale(nextLocale);

    if (i18n.setLocale) {
      await i18n.setLocale(normalizedLocale);
    } else {
      writeI18nLocale(i18n, normalizedLocale);
    }

    preferenceStore.updatePreference('language', normalizedLocale);

    if (import.meta.client) {
      document.documentElement.setAttribute('lang', normalizedLocale);
    }
  }

  return {
    t,
    locale,
    localeOptions,
    setAppLocale
  };
}

export function useAppLocale(): AppLocaleContext {
  const i18n =
    useI18n() as unknown as I18nWithLocaleControls;

  return createAppLocaleContext(i18n);
}

export function useAppLocaleController(): AppLocaleContext {
  const nuxtApp =
    useNuxtApp() as unknown as NuxtAppWithI18n;

  if (!nuxtApp.$i18n) {
    throw new Error(
      '[useAppLocaleController] Nuxt i18n is not available'
    );
  }

  return createAppLocaleContext(nuxtApp.$i18n);
}
