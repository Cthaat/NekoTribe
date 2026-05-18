<script setup lang="ts">
import type { LucideIcon } from 'lucide-vue-next';
import {
  ArrowUpRight,
  BadgeCheck,
  Bot,
  Database,
  Github,
  MessageSquare,
  RadioTower,
  ShieldCheck,
  Sparkles,
  Users
} from 'lucide-vue-next';
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle
} from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Separator } from '@/components/ui/separator';
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

interface FeatureCard {
  title: string;
  description: string;
  icon: LucideIcon;
}

interface RelatedLink {
  title: string;
  description: string;
  url: string;
  external: boolean;
  icon: LucideIcon;
}

interface VersionCard {
  label: string;
  config: VersionConfig;
}

const { t } = useAppLocale();
const localePath = useLocalePath();

const repositoryUrl = 'https://github.com/Cthaat/NekoTribe';
const issuesUrl = `${repositoryUrl}/issues`;
const docsUrl = `${repositoryUrl}/tree/main/doc`;

const features = computed<FeatureCard[]>(() => [
  {
    title: t('about.features.social.title'),
    description: t('about.features.social.description'),
    icon: Sparkles
  },
  {
    title: t('about.features.groups.title'),
    description: t('about.features.groups.description'),
    icon: Users
  },
  {
    title: t('about.features.realtime.title'),
    description: t('about.features.realtime.description'),
    icon: MessageSquare
  },
  {
    title: t('about.features.safety.title'),
    description: t('about.features.safety.description'),
    icon: ShieldCheck
  }
]);

const relatedLinks = computed<RelatedLink[]>(() => [
  {
    title: t('about.links.repository.title'),
    description: t('about.links.repository.description'),
    url: repositoryUrl,
    external: true,
    icon: Github
  },
  {
    title: t('about.links.docs.title'),
    description: t('about.links.docs.description'),
    url: docsUrl,
    external: true,
    icon: BadgeCheck
  },
  {
    title: t('about.links.feedback.title'),
    description: t('about.links.feedback.description'),
    url: issuesUrl,
    external: true,
    icon: RadioTower
  },
  {
    title: t('about.links.groups.title'),
    description: t('about.links.groups.description'),
    url: localePath('/groups/discover'),
    external: false,
    icon: Users
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
  return value ? value.slice(0, 10) : t('about.versions.unknown');
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
    <div class="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-6 sm:px-6 lg:px-8">
      <section class="space-y-5">
        <Badge variant="secondary" class="w-fit gap-1.5">
          <Bot class="h-3.5 w-3.5" />
          {{ t('about.badge') }}
        </Badge>

        <div class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
          <div class="max-w-3xl space-y-3">
            <h1 class="text-3xl font-semibold tracking-normal sm:text-4xl">
              {{ t('about.title') }}
            </h1>
            <p class="text-base leading-7 text-muted-foreground">
              {{ t('about.description') }}
            </p>
          </div>

          <div class="flex flex-wrap gap-2">
            <Button as-child>
              <a
                :href="repositoryUrl"
                target="_blank"
                rel="noreferrer noopener"
              >
                <Github class="h-4 w-4" />
                {{ t('about.actions.repository') }}
              </a>
            </Button>
            <Button variant="outline" as-child>
              <NuxtLink :to="localePath('/')">
                {{ t('about.actions.backHome') }}
              </NuxtLink>
            </Button>
          </div>
        </div>
      </section>

      <Separator />

      <section class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <Card
          v-for="feature in features"
          :key="feature.title"
          class="bg-card/70"
        >
          <CardHeader class="gap-3">
            <div class="flex items-center gap-3">
              <span class="rounded-lg bg-primary/10 p-2 text-primary">
                <component :is="feature.icon" class="h-4 w-4" />
              </span>
              <CardTitle class="text-base">
                {{ feature.title }}
              </CardTitle>
            </div>
            <CardDescription class="leading-6">
              {{ feature.description }}
            </CardDescription>
          </CardHeader>
        </Card>
      </section>

      <section class="grid gap-6 lg:grid-cols-[minmax(0,1.35fr)_minmax(320px,0.65fr)]">
        <div class="space-y-3">
          <div>
            <h2 class="text-xl font-semibold tracking-normal">
              {{ t('about.links.title') }}
            </h2>
            <p class="mt-1 text-sm text-muted-foreground">
              {{ t('about.links.description') }}
            </p>
          </div>

          <div class="grid gap-3 sm:grid-cols-2">
            <a
              v-for="link in relatedLinks"
              :key="link.title"
              :href="link.url"
              :target="link.external ? '_blank' : undefined"
              :rel="link.external ? 'noreferrer noopener' : undefined"
              class="group rounded-lg border bg-card p-4 text-card-foreground transition-colors hover:bg-muted/60"
              @click="handleRelatedLinkClick(link, $event)"
            >
              <div class="flex items-start justify-between gap-3">
                <span class="rounded-lg bg-muted p-2 text-foreground">
                  <component :is="link.icon" class="h-4 w-4" />
                </span>
                <ArrowUpRight
                  class="h-4 w-4 text-muted-foreground transition-transform group-hover:-translate-y-0.5 group-hover:translate-x-0.5"
                />
              </div>
              <h3 class="mt-4 text-sm font-medium">
                {{ link.title }}
              </h3>
              <p class="mt-1 text-sm leading-6 text-muted-foreground">
                {{ link.description }}
              </p>
            </a>
          </div>
        </div>

        <Card class="h-fit bg-card/70">
          <CardHeader>
            <CardTitle class="text-xl">
              {{ t('about.versions.title') }}
            </CardTitle>
            <CardDescription>
              {{ t('about.versions.description') }}
            </CardDescription>
          </CardHeader>
          <CardContent class="space-y-4">
            <div
              v-for="item in versions"
              :key="item.label"
              class="rounded-lg border bg-background p-4"
            >
              <div class="flex items-start justify-between gap-3">
                <div>
                  <p class="text-sm font-medium">
                    {{ item.label }}
                  </p>
                  <p class="mt-1 text-xs text-muted-foreground">
                    {{ item.config.serviceName }}
                  </p>
                </div>
                <Badge variant="outline">
                  v{{ item.config.version }}
                </Badge>
              </div>
              <dl class="mt-4 grid grid-cols-2 gap-3 text-xs">
                <div>
                  <dt class="text-muted-foreground">
                    {{ t('about.versions.build') }}
                  </dt>
                  <dd class="mt-1 font-medium">
                    {{ item.config.buildNumber }}
                  </dd>
                </div>
                <div>
                  <dt class="text-muted-foreground">
                    {{ t('about.versions.releaseDate') }}
                  </dt>
                  <dd class="mt-1 font-medium">
                    {{ releaseDateLabel(item.config.releaseDate) }}
                  </dd>
                </div>
              </dl>
            </div>
          </CardContent>
        </Card>
      </section>
    </div>
  </main>
</template>
