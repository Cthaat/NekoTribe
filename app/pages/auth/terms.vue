<script setup lang="ts">
definePageMeta({
  layout: false
});
import { Separator } from '@/components/ui/separator';
import {
  Alert,
  AlertDescription,
  AlertTitle
} from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger
} from '@/components/ui/accordion';
import { AlertTriangle, FileText } from 'lucide-vue-next';

const { t } = useAppLocale();

// 2. 使用 useLocalePath 来处理路由
const localePath = useLocalePath();

// 2. 为目录和 FAQ 定义数据 (在实际应用中，这些也可以来自 props 或 API)
const tocItems = [
  {
    id: '#acceptance',
    titleKey: 'auth.terms.toc.acceptance'
  },
  {
    id: '#accounts',
    titleKey: 'auth.terms.toc.accounts'
  },
  { id: '#conduct', titleKey: 'auth.terms.toc.conduct' },
  {
    id: '#termination',
    titleKey: 'auth.terms.toc.termination'
  },
  { id: '#faq', titleKey: 'auth.terms.toc.faq' }
];

const faqItems = [
  {
    value: 'faq-1',
    questionKey: 'auth.terms.faq.q1.question',
    answerKey: 'auth.terms.faq.q1.answer'
  },
  {
    value: 'faq-2',
    questionKey: 'auth.terms.faq.q2.question',
    answerKey: 'auth.terms.faq.q2.answer'
  },
  {
    value: 'faq-3',
    questionKey: 'auth.terms.faq.q3.question',
    answerKey: 'auth.terms.faq.q3.answer'
  }
];
</script>

<template>
  <div class="mx-auto w-full max-w-4xl p-4 md:p-8">
    <article
      class="rounded-xl border border-border/60 bg-card shadow-none"
    >
      <header class="px-6 py-5 sm:px-8 sm:py-6">
        <div class="flex items-center gap-3">
          <span
            class="flex h-11 w-11 items-center justify-center rounded-lg bg-primary/10 text-primary ring-1 ring-primary/20"
          >
            <FileText class="h-5 w-5" />
          </span>
          <div class="min-w-0">
            <h1 class="text-2xl font-semibold tracking-tight sm:text-3xl">
              {{ t('auth.terms.title') }}
            </h1>
            <p class="mt-1 text-sm text-muted-foreground">
              {{ t('auth.terms.description') }}
            </p>
          </div>
        </div>
        <p class="mt-3 text-[11px] text-muted-foreground">
          {{ t('auth.terms.lastUpdated') }}: 2025.7.16
        </p>
      </header>

      <Separator />

      <div class="grid gap-8 px-6 py-6 sm:px-8 sm:py-8">
        <nav
          class="rounded-lg border border-border/60 bg-muted/30 p-4"
        >
          <h3 class="mb-2 text-sm font-semibold tracking-tight">
            {{ t('auth.terms.toc.title') }}
          </h3>
          <ul class="grid gap-1 text-sm">
            <li v-for="item in tocItems" :key="item.id">
              <a
                :href="item.id"
                class="inline-flex items-center gap-1.5 text-muted-foreground transition hover:text-foreground hover:underline"
              >
                <span class="text-primary">→</span>
                {{ t(item.titleKey) }}
              </a>
            </li>
          </ul>
        </nav>

        <article class="grid gap-8">
          <section :id="tocItems[0].id.substring(1)">
            <h2
              class="mb-4 border-b border-border/60 pb-2 text-xl font-semibold tracking-tight sm:text-2xl"
            >
              1. {{ t('auth.terms.sections.acceptance.title') }}
            </h2>
            <p class="text-sm leading-relaxed text-muted-foreground">
              {{ t('auth.terms.sections.acceptance.content') }}
            </p>
          </section>

          <section :id="tocItems[1].id.substring(1)">
            <h2
              class="mb-4 border-b border-border/60 pb-2 text-xl font-semibold tracking-tight sm:text-2xl"
            >
              2. {{ t('auth.terms.sections.accounts.title') }}
            </h2>
            <p class="text-sm leading-relaxed text-muted-foreground">
              {{ t('auth.terms.sections.accounts.content') }}
            </p>
          </section>

          <section :id="tocItems[2].id.substring(1)">
            <h2
              class="mb-4 border-b border-border/60 pb-2 text-xl font-semibold tracking-tight sm:text-2xl"
            >
              3. {{ t('auth.terms.sections.conduct.title') }}
            </h2>
            <p class="mb-4 text-sm leading-relaxed text-muted-foreground">
              {{ t('auth.terms.sections.conduct.content') }}
            </p>

            <Alert variant="destructive">
              <AlertTriangle class="h-4 w-4" />
              <AlertTitle>{{
                t('auth.terms.sections.conduct.alertTitle')
              }}</AlertTitle>
              <AlertDescription>
                <ul class="mt-2 list-disc space-y-1 pl-5">
                  <li>
                    {{ t('auth.terms.sections.conduct.prohibited.item1') }}
                  </li>
                  <li>
                    {{ t('auth.terms.sections.conduct.prohibited.item2') }}
                  </li>
                  <li>
                    {{ t('auth.terms.sections.conduct.prohibited.item3') }}
                  </li>
                </ul>
              </AlertDescription>
            </Alert>
          </section>

          <section :id="tocItems[3].id.substring(1)">
            <h2
              class="mb-4 border-b border-border/60 pb-2 text-xl font-semibold tracking-tight sm:text-2xl"
            >
              4. {{ t('auth.terms.sections.termination.title') }}
            </h2>
            <p class="text-sm leading-relaxed text-muted-foreground">
              {{ t('auth.terms.sections.termination.content') }}
            </p>
          </section>

          <section :id="tocItems[4].id.substring(1)">
            <h2
              class="mb-4 border-b border-border/60 pb-2 text-xl font-semibold tracking-tight sm:text-2xl"
            >
              5. {{ t('auth.terms.faq.title') }}
            </h2>
            <p class="mb-4 text-sm leading-relaxed text-muted-foreground">
              {{ t('auth.terms.faq.description') }}
            </p>
            <Separator class="my-4" />
            <Accordion type="single" collapsible class="w-full">
              <AccordionItem
                v-for="faq in faqItems"
                :key="faq.value"
                :value="faq.value"
              >
                <AccordionTrigger>{{ t(faq.questionKey) }}</AccordionTrigger>
                <AccordionContent class="text-sm leading-relaxed">
                  {{ t(faq.answerKey) }}
                </AccordionContent>
              </AccordionItem>
            </Accordion>
            <div class="mt-6 flex justify-center">
              <Button
                class="h-9 rounded-md shadow-xs"
                @click="$router.push(localePath('auth-sign-up'))"
              >
                {{ t('auth.terms.registerButton') }}
              </Button>
            </div>
          </section>
        </article>
      </div>
    </article>
  </div>
</template>
