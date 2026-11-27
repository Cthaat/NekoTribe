<script setup lang="ts">
import type { LucideIcon } from 'lucide-vue-next';
import {
  ArrowUpRight,
  BadgeCheck,
  Bot,
  Github,
  MessageSquare,
  RadioTower,
  ShieldCheck,
  Sparkles,
  Users
} from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import nekoVersion from '../../config/versions/Neko.json';
import oracleServerVersion from '../../config/versions/oracle-server.json';
import shadcnWebVersion from '../../config/versions/shadcn-web.json';

definePageMeta({
  layout: 'default'
});

interface VersionConfig {
  serviceName: string;
  version: string;
  tag: string;
  releaseDate: string;
  buildNumber: string;
}

type Tone = 'primary' | 'sky' | 'emerald' | 'amber' | 'violet';

interface FeatureCard {
  title: string;
  description: string;
  icon: LucideIcon;
  tone: Tone;
  links?: { label: string; to: string }[];
}

interface RelatedLink {
  title: string;
  description: string;
  url: string;
  external: boolean;
  icon: LucideIcon;
  tone: Tone;
}

interface VersionCard {
  label: string;
  config: VersionConfig;
}

const { t } = useAppLocale();
const localePath = useLocalePath();

const repositoryUrl = 'https://github.com/Cthaat/NekoTribe';
const issuesUrl = `${repositoryUrl}/issues`;
const docsUrl = `${repositoryUrl}/tree/master/docs`;

const toneIconClassMap: Record<Tone, string> = {
  primary: 'bg-primary/10 text-primary',
  sky: 'bg-sky-500/10 text-sky-600 dark:text-sky-400',
  emerald:
    'bg-emerald-500/10 text-emerald-600 dark:text-emerald-400',
  amber: 'bg-amber-500/10 text-amber-600 dark:text-amber-400',
  violet:
    'bg-violet-500/10 text-violet-600 dark:text-violet-400'
};

const features = computed<FeatureCard[]>(() => [
  {
    title: t('about.features.social.title'),
    description: t('about.features.social.description'),
    icon: Sparkles,
    tone: 'primary'
  },
  {
    title: t('about.features.groups.title'),
    description: t('about.features.groups.description'),
    icon: Users,
    tone: 'sky'
  },
  {
    title: t('about.features.realtime.title'),
    description: t('about.features.realtime.description'),
    icon: MessageSquare,
    tone: 'emerald'
  },
  {
    title: t('about.features.safety.title'),
    description: t('about.features.safety.description'),
    icon: ShieldCheck,
    tone: 'amber'
  },
  {
    title: t('about.features.ai.title'),
    description: t('about.features.ai.description'),
    icon: Bot,
    tone: 'violet',
    links: [
      { label: t('aiKnowledge.title'), to: localePath('/ai/knowledge') },
      { label: t('aiWriting.title'), to: localePath('/ai/writing') }
    ]
  }
]);

const relatedLinks = computed<RelatedLink[]>(() => [
  {
    title: t('about.links.repository.title'),
    description: t('about.links.repository.description'),
    url: repositoryUrl,
    external: true,
    icon: Github,
    tone: 'primary'
  },
  {
    title: t('about.links.docs.title'),
    description: t('about.links.docs.description'),
    url: docsUrl,
    external: true,
    icon: BadgeCheck,
    tone: 'emerald'
  },
  {
    title: t('about.links.feedback.title'),
    description: t('about.links.feedback.description'),
    url: issuesUrl,
    external: true,
    icon: RadioTower,
    tone: 'amber'
  },
  {
    title: t('about.links.groups.title'),
    description: t('about.links.groups.description'),
    url: localePath('/groups/discover'),
    external: false,
    icon: Users,
    tone: 'sky'
  }
]);

const versions = computed<VersionCard[]>(() => [
  {
    label: t('about.versions.app'),
    config: nekoVersion
  },
  {
    label: t('about.versions.web'),
    config: shadcnWebVersion
  },
  {
    label: t('about.versions.server'),
    config: oracleServerVersion
  }
]);

function releaseDateLabel(value: string): string {
  return value
    ? value.slice(0, 10)
    : t('about.versions.unknown');
}

function handleRelatedLinkClick(
  link: RelatedLink,
  event: MouseEvent
): void {
  if (link.external) {
    return;
  }

  event.preventDefault();
  void navigateTo(link.url);
}
</script>

<template>
  <main class="min-h-[calc(100dvh-4rem)]">
    <div
      class="mx-auto grid max-w-6xl gap-6 px-4 py-6 sm:px-6 lg:px-8"
    >
      <section class="bento-card grid gap-5 p-6 sm:p-8">
        <span
          class="inline-flex w-fit items-center gap-1.5 rounded-full bg-[var(--primary-soft)] px-3 py-1 text-[11px] font-semibold text-primary"
        >
          <Bot class="h-3.5 w-3.5" />
          {{ t('about.badge') }}
        </span>

        <div
          class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between"
        >
          <div class="max-w-3xl grid gap-3">
            <h1
              class="text-3xl font-semibold tracking-tight sm:text-4xl"
            >
              {{ t('about.title') }}
            </h1>
            <p class="text-sm leading-7 text-muted-foreground sm:text-base">
              {{ t('about.description') }}
            </p>
          </div>

          <div class="flex flex-wrap gap-2">
            <Button as-child class="pressable h-10 rounded-full px-5 shadow-none">
              <a
                :href="repositoryUrl"
                target="_blank"
                rel="noreferrer noopener"
              >
                <Github class="h-4 w-4" />
                {{ t('about.actions.repository') }}
              </a>
            </Button>
            <Button
              variant="secondary"
              as-child
              class="pressable h-10 rounded-full px-5 shadow-none"
            >
              <NuxtLink :to="localePath('/')">
                {{ t('about.actions.backHome') }}
              </NuxtLink>
            </Button>
          </div>
        </div>
      </section>

      <section class="grid gap-3.5 sm:grid-cols-2 xl:grid-cols-4">
        <div
          v-for="feature in features"
          :key="feature.title"
          class="bento-card grid gap-3 p-5 transition-colors hover:bg-card/90"
          :class="{ 'sm:col-span-2 xl:col-span-4': feature.links }"
        >
          <div class="flex items-center gap-3">
            <span
              class="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl"
              :class="toneIconClassMap[feature.tone]"
            >
              <component :is="feature.icon" class="h-4 w-4" />
            </span>
            <h3 class="text-sm font-semibold tracking-tight">
              {{ feature.title }}
            </h3>
          </div>
          <p class="text-xs leading-6 text-muted-foreground">
            {{ feature.description }}
          </p>
          <div v-if="feature.links" class="flex flex-wrap items-center gap-2">
            <Button
              v-for="link in feature.links"
              :key="link.to"
              as-child
              size="sm"
              variant="secondary"
              class="pressable rounded-full px-4 shadow-none"
            >
              <NuxtLink :to="link.to">{{ link.label }}</NuxtLink>
            </Button>
          </div>
        </div>
      </section>

      <section
        class="grid gap-6 lg:grid-cols-[minmax(0,1.35fr)_minmax(320px,0.65fr)]"
      >
        <div class="grid gap-3.5">
          <div class="grid gap-1 px-1">
            <h2 class="text-base font-semibold tracking-tight">
              {{ t('about.links.title') }}
            </h2>
            <p class="text-xs text-muted-foreground">
              {{ t('about.links.description') }}
            </p>
          </div>

          <div class="grid gap-3.5 sm:grid-cols-2">
            <a
              v-for="link in relatedLinks"
              :key="link.title"
              :href="link.url"
              :target="link.external ? '_blank' : undefined"
              :rel="
                link.external ? 'noreferrer noopener' : undefined
              "
              class="bento-card pressable group grid gap-3 p-5 text-card-foreground transition-colors hover:bg-secondary/60"
              @click="handleRelatedLinkClick(link, $event)"
            >
              <div class="flex items-start justify-between gap-3">
                <span
                  class="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl"
                  :class="toneIconClassMap[link.tone]"
                >
                  <component :is="link.icon" class="h-4 w-4" />
                </span>
                <ArrowUpRight
                  class="h-4 w-4 text-muted-foreground transition-transform duration-200 ease-[var(--ease-spring)] group-hover:-translate-y-0.5 group-hover:translate-x-0.5"
                />
              </div>
              <div class="grid gap-1">
                <h3 class="text-sm font-semibold tracking-tight">
                  {{ link.title }}
                </h3>
                <p class="text-xs leading-6 text-muted-foreground">
                  {{ link.description }}
                </p>
              </div>
            </a>
          </div>
        </div>

        <div
          class="bento-card grid h-fit gap-4 p-5"
        >
          <div class="grid gap-1">
            <h2 class="text-base font-semibold tracking-tight">
              {{ t('about.versions.title') }}
            </h2>
            <p class="text-xs text-muted-foreground">
              {{ t('about.versions.description') }}
            </p>
          </div>
          <div class="grid gap-3">
            <div
              v-for="item in versions"
              :key="item.label"
              class="bento-tile grid gap-3 p-3.5"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="grid gap-0.5">
                  <p class="text-sm font-semibold tracking-tight">
                    {{ item.label }}
                  </p>
                  <p class="text-[11px] text-muted-foreground">
                    {{ item.config.serviceName }}
                  </p>
                </div>
                <span
                  class="inline-flex items-center gap-1 rounded-full bg-[var(--primary-soft)] px-2.5 py-0.5 text-[11px] font-semibold tabular-nums text-primary"
                >
                  v{{ item.config.version }}
                </span>
              </div>
              <dl class="grid grid-cols-2 gap-3 text-xs">
                <div class="grid gap-0.5">
                  <dt class="text-[11px] text-muted-foreground">
                    {{ t('about.versions.build') }}
                  </dt>
                  <dd class="font-medium tabular-nums">
                    {{ item.config.buildNumber }}
                  </dd>
                </div>
                <div class="grid gap-0.5">
                  <dt class="text-[11px] text-muted-foreground">
                    {{ t('about.versions.releaseDate') }}
                  </dt>
                  <dd class="font-medium tabular-nums">
                    {{ releaseDateLabel(item.config.releaseDate) }}
                  </dd>
                </div>
              </dl>
            </div>
          </div>
        </div>
      </section>
    </div>
  </main>
</template>
