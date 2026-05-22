<script setup lang="ts">
import type { LucideIcon } from 'lucide-vue-next';
import {
  ArrowRight,
  Bot,
  CheckCircle2,
  Crown,
  Gauge,
  MessageSquare,
  ShieldCheck,
  Zap
} from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { Progress } from '@/components/ui/progress';

const { t } = useAppLocale();
const localePath = useLocalePath();

interface ProFeature {
  title: string;
  description: string;
  icon: LucideIcon;
  tone: 'primary' | 'sky' | 'emerald' | 'amber';
}

interface ProPlan {
  name: string;
  price: string;
  description: string;
  badge?: string;
  featured?: boolean;
  features: string[];
}

const PILL_BASE =
  'inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-medium';

const features = computed<ProFeature[]>(() => [
  {
    title: t('account.pro.features.ai.title'),
    description: t('account.pro.features.ai.description'),
    icon: Bot,
    tone: 'primary'
  },
  {
    title: t('account.pro.features.realtime.title'),
    description: t('account.pro.features.realtime.description'),
    icon: MessageSquare,
    tone: 'sky'
  },
  {
    title: t('account.pro.features.safety.title'),
    description: t('account.pro.features.safety.description'),
    icon: ShieldCheck,
    tone: 'emerald'
  },
  {
    title: t('account.pro.features.speed.title'),
    description: t('account.pro.features.speed.description'),
    icon: Zap,
    tone: 'amber'
  }
]);

function featureToneClass(tone: ProFeature['tone']): string {
  switch (tone) {
    case 'sky':
      return 'bg-sky-500/10 text-sky-600 dark:text-sky-400';
    case 'emerald':
      return 'bg-emerald-500/10 text-emerald-600 dark:text-emerald-400';
    case 'amber':
      return 'bg-amber-500/10 text-amber-600 dark:text-amber-400';
    case 'primary':
    default:
      return 'bg-primary/10 text-primary';
  }
}

const plans = computed<ProPlan[]>(() => [
  {
    name: t('account.pro.plans.free.name'),
    price: t('account.pro.plans.free.price'),
    description: t('account.pro.plans.free.description'),
    features: [
      t('account.pro.plans.free.feature1'),
      t('account.pro.plans.free.feature2'),
      t('account.pro.plans.free.feature3')
    ]
  },
  {
    name: t('account.pro.plans.pro.name'),
    price: t('account.pro.plans.pro.price'),
    description: t('account.pro.plans.pro.description'),
    badge: t('account.pro.plans.pro.badge'),
    featured: true,
    features: [
      t('account.pro.plans.pro.feature1'),
      t('account.pro.plans.pro.feature2'),
      t('account.pro.plans.pro.feature3')
    ]
  },
  {
    name: t('account.pro.plans.team.name'),
    price: t('account.pro.plans.team.price'),
    description: t('account.pro.plans.team.description'),
    features: [
      t('account.pro.plans.team.feature1'),
      t('account.pro.plans.team.feature2'),
      t('account.pro.plans.team.feature3')
    ]
  }
]);
</script>

<template>
  <div class="grid gap-6">
    <section
      class="grid gap-6 lg:grid-cols-[minmax(0,1.35fr)_minmax(320px,0.65fr)]"
    >
      <div
        class="grid gap-5 rounded-xl border border-border/60 bg-gradient-to-br from-primary/5 via-card to-card p-6 shadow-none sm:p-8"
      >
        <span
          :class="[
            PILL_BASE,
            'w-fit border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300'
          ]"
        >
          <Crown class="h-3 w-3" />
          {{ t('account.pro.badge') }}
        </span>
        <div class="max-w-3xl grid gap-2">
          <h2
            class="text-2xl font-semibold tracking-tight sm:text-3xl"
          >
            {{ t('account.pro.title') }}
          </h2>
          <p
            class="text-sm leading-relaxed text-muted-foreground sm:text-base"
          >
            {{ t('account.pro.description') }}
          </p>
        </div>
        <div class="flex flex-col gap-2 sm:flex-row">
          <Button as-child class="h-9 rounded-md shadow-xs">
            <NuxtLink :to="localePath('account-billing')">
              {{ t('account.pro.actions.upgrade') }}
              <ArrowRight class="h-3.5 w-3.5" />
            </NuxtLink>
          </Button>
          <Button
            variant="outline"
            class="h-9 rounded-md shadow-xs"
            as-child
          >
            <NuxtLink :to="localePath('account-settings')">
              {{ t('account.pro.actions.settings') }}
            </NuxtLink>
          </Button>
        </div>
      </div>

      <section
        class="grid gap-5 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
      >
        <header class="flex items-start gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
          >
            <Gauge class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h3 class="text-base font-semibold tracking-tight">
              {{ t('account.pro.status.title') }}
            </h3>
            <p class="text-xs text-muted-foreground">
              {{ t('account.pro.status.description') }}
            </p>
          </div>
        </header>

        <div
          class="flex items-center justify-between gap-3 rounded-lg border border-border/60 bg-muted/20 p-3"
        >
          <div class="min-w-0">
            <p class="text-[11px] uppercase tracking-wider text-muted-foreground">
              {{ t('account.pro.status.current') }}
            </p>
            <p class="mt-0.5 text-sm font-semibold">
              {{ t('account.pro.status.plan') }}
            </p>
          </div>
          <span
            :class="[
              PILL_BASE,
              'border-border/60 bg-muted/40 text-muted-foreground'
            ]"
          >
            {{ t('account.pro.status.badge') }}
          </span>
        </div>

        <div class="grid gap-4">
          <div class="grid gap-1.5">
            <div class="flex items-center justify-between text-xs">
              <span class="font-medium">
                {{ t('account.pro.status.storage') }}
              </span>
              <span
                class="font-mono tabular-nums text-muted-foreground"
              >42%</span>
            </div>
            <Progress :model-value="42" class="h-1.5" />
          </div>
          <div class="grid gap-1.5">
            <div class="flex items-center justify-between text-xs">
              <span class="font-medium">
                {{ t('account.pro.status.aiQuota') }}
              </span>
              <span
                class="font-mono tabular-nums text-muted-foreground"
              >68%</span>
            </div>
            <Progress :model-value="68" class="h-1.5" />
          </div>
        </div>
      </section>
    </section>

    <section class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
      <article
        v-for="feature in features"
        :key="feature.title"
        class="grid gap-3 rounded-xl border border-border/60 bg-card p-5 shadow-none transition-all hover:border-border hover:shadow-md"
      >
        <div class="flex items-center gap-3">
          <span
            :class="[
              'flex h-9 w-9 shrink-0 items-center justify-center rounded-md',
              featureToneClass(feature.tone)
            ]"
          >
            <component :is="feature.icon" class="h-4 w-4" />
          </span>
          <h3 class="text-sm font-semibold tracking-tight">
            {{ feature.title }}
          </h3>
        </div>
        <p class="text-xs leading-relaxed text-muted-foreground">
          {{ feature.description }}
        </p>
      </article>
    </section>

    <section class="grid gap-4 lg:grid-cols-3">
      <article
        v-for="plan in plans"
        :key="plan.name"
        :class="[
          'relative grid gap-5 rounded-xl border bg-card p-6 shadow-none transition-all',
          plan.featured
            ? 'border-primary/40 shadow-md ring-1 ring-primary/10'
            : 'border-border/60 hover:border-border hover:shadow-md'
        ]"
      >
        <span
          v-if="plan.badge"
          :class="[
            PILL_BASE,
            'absolute right-4 top-4 border-primary/30 bg-primary/10 text-primary'
          ]"
        >
          {{ plan.badge }}
        </span>
        <header class="grid gap-1">
          <h3 class="text-lg font-semibold tracking-tight">
            {{ plan.name }}
          </h3>
          <p class="text-xs text-muted-foreground">
            {{ plan.description }}
          </p>
        </header>
        <div class="flex items-baseline gap-1">
          <span
            class="text-3xl font-semibold tracking-tight tabular-nums"
          >
            {{ plan.price }}
          </span>
          <span class="text-xs text-muted-foreground">
            {{ t('account.pro.plans.period') }}
          </span>
        </div>
        <div class="h-px w-full bg-border/60" />
        <ul class="grid gap-2.5 text-sm">
          <li
            v-for="feature in plan.features"
            :key="feature"
            class="flex items-start gap-2"
          >
            <CheckCircle2
              class="mt-0.5 h-4 w-4 shrink-0 text-emerald-500 dark:text-emerald-400"
            />
            <span class="leading-relaxed">{{ feature }}</span>
          </li>
        </ul>
        <Button
          class="h-9 w-full rounded-md shadow-xs"
          :variant="plan.featured ? 'default' : 'outline'"
          as-child
        >
          <NuxtLink :to="localePath('account-billing')">
            {{
              plan.featured
                ? t('account.pro.actions.upgrade')
                : t('account.pro.actions.viewPlan')
            }}
          </NuxtLink>
        </Button>
      </article>
    </section>
  </div>
</template>
