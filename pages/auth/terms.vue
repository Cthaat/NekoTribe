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
import { Button } from '@/components/ui/button';
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger
} from '@/components/ui/accordion';
import { AlertTriangle, FileText } from 'lucide-vue-next';
import { useI18n } from 'vue-i18n';

const { t } = useI18n();

// 2. 使用 useLocalePath 来处理路由
const localePath = useLocalePath();

// 2. 为目录和 FAQ 定义数据 (在实际应用中，这些也可以来自 props 或 API)
const tocItems = [
  {
    id: '#acceptance',
    titleKey: t('auth.terms.toc.acceptance')
  },
  {
    id: '#accounts',
    titleKey: t('auth.terms.toc.accounts')
  },
  { id: '#conduct', titleKey: t('auth.terms.toc.conduct') },
  {
    id: '#termination',
    titleKey: t('auth.terms.toc.termination')
  },
  { id: '#faq', titleKey: t('auth.terms.toc.faq') }
];

const faqItems = [
  {
    value: 'faq-1',
    questionKey: t('auth.terms.faq.q1.question'),
    answerKey: t('auth.terms.faq.q1.answer')
  },
  {
    value: 'faq-2',
    questionKey: t('auth.terms.faq.q2.question'),
    answerKey: t('auth.terms.faq.q2.answer')
  },
  {
    value: 'faq-3',
    questionKey: t('auth.terms.faq.q3.question'),
    answerKey: t('auth.terms.faq.q3.answer')
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
              {{ $t('auth.terms.title') }}
            </CardTitle>
            <CardDescription>
              {{ $t('auth.terms.description') }}
            </CardDescription>
          </div>
        </div>
        <p class="text-xs text-muted-foreground pt-2">
          {{ $t('auth.terms.lastUpdated') }}: 2025.7.16
        </p>
      </CardHeader>

      <Separator />

      <CardContent class="p-6 space-y-8">
        <!-- 目录 (Table of Contents) -->
        <div class="p-4 bg-muted/50 rounded-lg">
          <h3 class="font-semibold mb-2">
            {{ $t('auth.terms.toc.title') }}
          </h3>
          <ul class="space-y-1 list-inside">
            <li v-for="item in tocItems" :key="item.id">
              <a :href="item.id" class="hover:underline">
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
              1.
              {{
                $t('auth.terms.sections.acceptance.title')
              }}
            </h2>
            <p class="leading-relaxed">
              {{
                $t('auth.terms.sections.acceptance.content')
              }}
            </p>
          </section>

          <!-- 章节 2: 账户责任 -->
          <section :id="tocItems[1].id.substring(1)">
            <h2
              class="text-2xl font-semibold border-b pb-2 mb-4"
            >
              2.
              {{ $t('auth.terms.sections.accounts.title') }}
            </h2>
            <p class="leading-relaxed">
              {{
                $t('auth.terms.sections.accounts.content')
              }}
            </p>
          </section>

          <!-- 章节 3: 用户行为 -->
          <section :id="tocItems[2].id.substring(1)">
            <h2
              class="text-2xl font-semibold border-b pb-2 mb-4"
            >
              3.
              {{ $t('auth.terms.sections.conduct.title') }}
            </h2>
            <p class="leading-relaxed mb-4">
              {{
                $t('auth.terms.sections.conduct.content')
              }}
            </p>

            <!-- 使用 Alert 组件突出显示重要信息 -->
            <Alert variant="destructive">
              <AlertTriangle class="h-4 w-4" />
              <AlertTitle>{{
                $t('auth.terms.sections.conduct.alertTitle')
              }}</AlertTitle>
              <AlertDescription>
                <ul class="list-disc pl-5 mt-2">
                  <li>
                    {{
                      $t(
                        'auth.terms.sections.conduct.prohibited.item1'
                      )
                    }}
                  </li>
                  <li>
                    {{
                      $t(
                        'auth.terms.sections.conduct.prohibited.item2'
                      )
                    }}
                  </li>
                  <li>
                    {{
                      $t(
                        'auth.terms.sections.conduct.prohibited.item3'
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
              {{
                $t('auth.terms.sections.termination.title')
              }}
            </h2>
            <p class="leading-relaxed">
              {{
                $t(
                  'auth.terms.sections.termination.content'
                )
              }}
            </p>
          </section>

          <!-- 章节 5: 常见问题 (FAQ) -->
          <section :id="tocItems[4].id.substring(1)">
            <h2
              class="text-2xl font-semibold border-b pb-2 mb-4"
            >
              5. {{ $t('auth.terms.faq.title') }}
            </h2>
            <p class="leading-relaxed mb-4">
              {{ $t('auth.terms.faq.description') }}
            </p>
            <!-- 分割线 -->
            <Separator class="my-4" />
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
            <!-- 添加返回注册的按钮，居中 -->
            <div
              class="mt-6 flex content-center justify-center"
            >
              <Button
                @click="
                  $router.push(localePath('auth-sign-up'))
                "
              >
                {{ $t('auth.terms.registerButton') }}
              </Button>
            </div>
          </section>
        </article>
      </CardContent>
    </Card>
  </div>
</template>
