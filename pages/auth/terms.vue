<script setup lang="ts">
// 无页面布局
definePageMeta({
  layout: false
});
// 1. 导入所有需要的组件
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle
} from '@/components/ui/card';
import { Separator } from '@/components/ui/separator';
import {
  Alert,
  AlertDescription,
  AlertTitle
} from '@/components/ui/alert';
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger
} from '@/components/ui/accordion';
import { AlertTriangle, FileText } from 'lucide-vue-next';

// 2. 为目录和 FAQ 定义数据 (在实际应用中，这些也可以来自 props 或 API)
const tocItems = [
  { id: '#acceptance', titleKey: 'terms.toc.acceptance' },
  { id: '#accounts', titleKey: 'terms.toc.accounts' },
  { id: '#conduct', titleKey: 'terms.toc.conduct' },
  { id: '#termination', titleKey: 'terms.toc.termination' },
  { id: '#faq', titleKey: 'terms.toc.faq' }
];

const faqItems = [
  {
    value: 'faq-1',
    questionKey: 'terms.faq.q1.question',
    answerKey: 'terms.faq.q1.answer'
  },
  {
    value: 'faq-2',
    questionKey: 'terms.faq.q2.question',
    answerKey: 'terms.faq.q2.answer'
  },
  {
    value: 'faq-3',
    questionKey: 'terms.faq.q3.question',
    answerKey: 'terms.faq.q3.answer'
  }
];
</script>

<template>
  <div class="w-full max-w-4xl mx-auto p-4 md:p-8">
    <Card>
      <CardHeader>
        <div class="flex items-center gap-3 mb-2">
          <FileText class="size-8 text-primary" />
          <div>
            <CardTitle class="text-3xl font-bold">
              {{ $t('terms.title') }}
            </CardTitle>
            <CardDescription>
              {{ $t('terms.description') }}
            </CardDescription>
          </div>
        </div>
        <p class="text-xs text-muted-foreground pt-2">
          {{ $t('terms.lastUpdated') }}: 2025年7月16日
        </p>
      </CardHeader>

      <Separator />

      <CardContent class="p-6 space-y-8">
        <!-- 目录 (Table of Contents) -->
        <div class="p-4 bg-muted/50 rounded-lg">
          <h3 class="font-semibold mb-2">
            {{ $t('terms.toc.title') }}
          </h3>
          <ul class="space-y-1 list-inside">
            <li v-for="item in tocItems" :key="item.id">
              <a
                :href="item.id"
                class="text-blue-600 hover:underline"
              >
                {{ $t(item.titleKey) }}
              </a>
            </li>
          </ul>
        </div>

        <!-- 服务条款内容 -->
        <article class="space-y-6">
          <!-- 章节 1: 接受条款 -->
          <section :id="tocItems[0].id.substring(1)">
            <h2
              class="text-2xl font-semibold border-b pb-2 mb-4"
            >
              1. {{ $t('terms.sections.acceptance.title') }}
            </h2>
            <p class="leading-relaxed">
              {{ $t('terms.sections.acceptance.content') }}
            </p>
          </section>

          <!-- 章节 2: 账户责任 -->
          <section :id="tocItems[1].id.substring(1)">
            <h2
              class="text-2xl font-semibold border-b pb-2 mb-4"
            >
              2. {{ $t('terms.sections.accounts.title') }}
            </h2>
            <p class="leading-relaxed">
              {{ $t('terms.sections.accounts.content') }}
            </p>
          </section>

          <!-- 章节 3: 用户行为 -->
          <section :id="tocItems[2].id.substring(1)">
            <h2
              class="text-2xl font-semibold border-b pb-2 mb-4"
            >
              3. {{ $t('terms.sections.conduct.title') }}
            </h2>
            <p class="leading-relaxed mb-4">
              {{ $t('terms.sections.conduct.content') }}
            </p>

            <!-- 使用 Alert 组件突出显示重要信息 -->
            <Alert variant="destructive">
              <AlertTriangle class="h-4 w-4" />
              <AlertTitle>{{
                $t('terms.sections.conduct.alertTitle')
              }}</AlertTitle>
              <AlertDescription>
                <ul class="list-disc pl-5 mt-2">
                  <li>
                    {{
                      $t(
                        'terms.sections.conduct.prohibited.item1'
                      )
                    }}
                  </li>
                  <li>
                    {{
                      $t(
                        'terms.sections.conduct.prohibited.item2'
                      )
                    }}
                  </li>
                  <li>
                    {{
                      $t(
                        'terms.sections.conduct.prohibited.item3'
                      )
                    }}
                  </li>
                </ul>
              </AlertDescription>
            </Alert>
          </section>

          <!-- 章节 4: 终止服务 -->
          <section :id="tocItems[3].id.substring(1)">
            <h2
              class="text-2xl font-semibold border-b pb-2 mb-4"
            >
              4.
              {{ $t('terms.sections.termination.title') }}
            </h2>
            <p class="leading-relaxed">
              {{ $t('terms.sections.termination.content') }}
            </p>
          </section>

          <!-- 章节 5: 常见问题 (FAQ) -->
          <section :id="tocItems[4].id.substring(1)">
            <h2
              class="text-2xl font-semibold border-b pb-2 mb-4"
            >
              5. {{ $t('terms.faq.title') }}
            </h2>
            <Accordion
              type="single"
              collapsible
              class="w-full"
            >
              <AccordionItem
                v-for="faq in faqItems"
                :key="faq.value"
                :value="faq.value"
              >
                <AccordionTrigger>{{
                  $t(faq.questionKey)
                }}</AccordionTrigger>
                <AccordionContent class="text-base">
                  {{ $t(faq.answerKey) }}
                </AccordionContent>
              </AccordionItem>
            </Accordion>
          </section>
        </article>
      </CardContent>
    </Card>
  </div>
</template>
