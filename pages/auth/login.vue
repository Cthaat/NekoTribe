<script setup lang="ts">
import { Button } from '@/components/ui/button'
import { useI18n } from 'vue-i18n'
import { h } from 'vue'
import * as z from 'zod'
import { AutoForm } from '@/components/ui/auto-form'
import { toTypedSchema } from '@vee-validate/zod'
import { useForm } from 'vee-validate'
import { toast } from 'vue-sonner'
// 从你的 UI 库中导入这些基础表单组件
import {
  FormControl,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from '@/components/ui/form'
import { Input } from '@/components/ui/input' // 导入 Input 组件
const { t } = useI18n()

const description = t('auth.login.description')
const iframeHeight = '800px'
const containerClass = 'w-full h-full p-4 lg:p-0'

useHead({
  title: t('auth.login.title'),
  meta: [
    {
      name: 'description',
      content: description
    }
  ],
})


// 更新 schema 以匹配UI提示，并添加email验证
const schema = z.object({
  email: z.string()
    .min(1, { message: t('auth.login.emailRequired') })
    .email({ message: t('auth.login.emailInvalid') }),
  password: z.string()
    .min(1, { message: t('auth.login.passwordRequired') })
    .min(6, { message: t('auth.login.passwordTooShort') }),
})

const form = useForm({
  validationSchema: toTypedSchema(schema),
  initialValues: {
    email: '', // 将 email 的初始值设为空字符串
    password: '', // 将 password 的初始值设为空字符串
  },
})

// 3. 将你的提交逻辑放入一个只在验证成功时才调用的函数中
function onValidSubmit(values: Record<string, any>) {
  console.log('Validation passed, submitting data:', values)
  toast({
    title: 'You submitted the following values:',
    description: h('pre', { class: 'mt-2 w-[340px] rounded-md bg-slate-950 p-4' }, h('code', { class: 'text-white' }, JSON.stringify(values, null, 2))),
  })
  // 在这里执行页面跳转或API请求
}

// 4. 创建最终的 onSubmit 函数，它会先验证再决定是否执行 onValidSubmit
const onSubmit = form.handleSubmit(onValidSubmit)
</script>

<template>
  <div class="w-full lg:grid lg:min-h-[600px] lg:grid-cols-2 xl:min-h-[800px]">
    <div class="flex items-center justify-center py-12">
      <div class="mx-auto grid w-[350px] gap-6">
        <div class="grid gap-2 text-center">
          <h1 class="text-3xl font-bold">
            {{ $t('auth.login.title') }}
          </h1>
          <p class="text-balance text-muted-foreground">
            {{ $t('auth.login.loginPrompt') }}
          </p>
        </div>
        <!-- 使用标准的 form 和 FormField 进行重构 -->
        <form class="grid gap-4" :form="form" @submit="onSubmit">
          <FormField v-slot="{ componentField }" name="email">
            <FormItem>
              <FormLabel>{{ $t('auth.login.email') }}</FormLabel>
              <FormControl>
                <Input type="email" :placeholder="$t('auth.login.emailPlaceholder')" v-bind="componentField" />
              </FormControl>
              <FormMessage />
            </FormItem>
          </FormField>
          <FormField v-slot="{ componentField }" name="password">
            <FormItem>
              <FormLabel>{{ $t('auth.login.password') }}</FormLabel>
              <FormControl>
                <Input type="password" :placeholder="$t('auth.login.passwordPlaceholder')" v-bind="componentField" />
              </FormControl>
              <FormMessage />
            </FormItem>
          </FormField>
          <Button type="submit" class="w-full">
            {{ $t('auth.login.loginButton') }}
          </Button>
        </form>
        <div class="mt-4 text-center text-sm">
          {{ $t('auth.login.noAccount') }}
          <a href="#" class="underline">
            {{ $t('auth.login.signUp') }}
          </a>
        </div>
      </div>
    </div>
    <div class="hidden bg-muted lg:block">
      <img src="~/public/placeholder.svg" alt="Image" width="1920" height="1080"
        class="h-full w-full object-cover dark:brightness-[0.2] dark:grayscale">
    </div>
  </div>
</template>
