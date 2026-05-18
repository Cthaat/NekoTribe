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
  Sparkles,
  Zap
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
import { Progress } from '@/components/ui/progress';
import { Separator } from '@/components/ui/separator';

const { t } = useAppLocale();
const localePath = useLocalePath();

interface ProFeature {
  title: string;
  description: string;
  icon: LucideIcon;
}

interface ProPlan {
  name: string;
  price: string;
  description: string;
  badge?: string;
  featured?: boolean;
  features: string[];
}

const features = computed<ProFeature[]>(() => [
  {
    title: t('account.pro.features.ai.title'),
    description: t('account.pro.features.ai.description'),
    icon: Bot
  },
  {
    title: t('account.pro.features.realtime.title'),
    description: t('account.pro.features.realtime.description'),
    icon: MessageSquare
  },
  {
    title: t('account.pro.features.safety.title'),
    description: t('account.pro.features.safety.description'),
    icon: ShieldCheck
  },
  {
    title: t('account.pro.features.speed.title'),
    description: t('account.pro.features.speed.description'),
    icon: Zap
  }
]);

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
  <div class="space-y-6">
    <section class="grid gap-6 lg:grid-cols-[minmax(0,1.35fr)_minmax(320px,0.65fr)]">
      <div class="rounded-xl border bg-card p-6 text-card-foreground shadow-sm">
        <Badge variant="secondary" class="gap-1.5">
          <Crown class="h-3.5 w-3.5" />
          {{ t('account.pro.badge') }}
        </Badge>
        <div class="mt-5 max-w-3xl space-y-3">
          <h2 class="text-2xl font-semibold tracking-normal sm:text-3xl">
            {{ t('account.pro.title') }}
          </h2>
          <p class="text-sm leading-6 text-muted-foreground sm:text-base">
            {{ t('account.pro.description') }}
          </p>
        </div>
        <div class="mt-6 flex flex-col gap-2 sm:flex-row">
          <Button as-child class="gap-2">
            <NuxtLink :to="localePath('account-billing')">
              {{ t('account.pro.actions.upgrade') }}
              <ArrowRight class="h-4 w-4" />
            </NuxtLink>
          </Button>
          <Button variant="outline" as-child>
            <NuxtLink :to="localePath('account-settings')">
              {{ t('account.pro.actions.settings') }}
            </NuxtLink>
          </Button>
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle class="flex items-center gap-2 text-xl">
            <Gauge class="h-5 w-5 text-primary" />
            {{ t('account.pro.status.title') }}
          </CardTitle>
          <CardDescription>
            {{ t('account.pro.status.description') }}
          </CardDescription>
        </CardHeader>
        <CardContent class="space-y-5">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm text-muted-foreground">
                {{ t('account.pro.status.current') }}
              </p>
              <p class="mt-1 text-lg font-semibold">
                {{ t('account.pro.status.plan') }}
              </p>
            </div>
            <Badge variant="outline">
              {{ t('account.pro.status.badge') }}
            </Badge>
          </div>
          <Separator />
          <div class="space-y-2">
            <div class="flex items-center justify-between text-sm">
              <span>{{ t('account.pro.status.storage') }}</span>
              <span class="text-muted-foreground">42%</span>
            </div>
            <Progress :model-value="42" />
          </div>
          <div class="space-y-2">
            <div class="flex items-center justify-between text-sm">
              <span>{{ t('account.pro.status.aiQuota') }}</span>
              <span class="text-muted-foreground">68%</span>
            </div>
            <Progress :model-value="68" />
          </div>
        </CardContent>
      </Card>
    </section>

    <section class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
      <Card v-for="feature in features" :key="feature.title">
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

    <section class="grid gap-4 lg:grid-cols-3">
      <Card
        v-for="plan in plans"
        :key="plan.name"
        :class="plan.featured ? 'border-primary shadow-md' : ''"
      >
        <CardHeader>
          <div class="flex items-center justify-between gap-3">
            <CardTitle class="text-xl">
              {{ plan.name }}
            </CardTitle>
            <Badge v-if="plan.badge">
              {{ plan.badge }}
            </Badge>
          </div>
          <CardDescription>
            {{ plan.description }}
          </CardDescription>
        </CardHeader>
        <CardContent class="space-y-5">
          <div>
            <span class="text-3xl font-semibold tracking-normal">
              {{ plan.price }}
            </span>
            <span class="text-sm text-muted-foreground">
              {{ t('account.pro.plans.period') }}
            </span>
          </div>
          <Separator />
          <ul class="space-y-3 text-sm">
            <li
              v-for="feature in plan.features"
              :key="feature"
              class="flex items-start gap-2"
            >
              <CheckCircle2 class="mt-0.5 h-4 w-4 shrink-0 text-primary" />
              <span>{{ feature }}</span>
            </li>
          </ul>
          <Button
            class="w-full"
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
        </CardContent>
      </Card>
    </section>
  </div>
</template>
