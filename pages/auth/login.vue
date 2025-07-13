<script setup lang="ts">
import { Button } from '@/components/ui/button'
import { useI18n } from 'vue-i18n'
import { h } from 'vue'
import * as z from 'zod'
import { toTypedSchema } from '@vee-validate/zod'
import { useForm } from 'vee-validate'
import { toast } from 'vue-sonner'
import { useApiFetch } from '@/composables/useApiFetch' // 导入自定义的 useApiFetch 组合式 API
import { apiFetch } from '@/composables/useApi'
import { useRouter } from 'vue-router'
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

import { navigateTo } from '#app'

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


// 更新 schema 以匹配UI提示，并添加account验证
const schema = z.object({
  account: z.string()
    .min(1, { message: t('auth.login.accountRequired') }),
  password: z.string()
    .min(1, { message: t('auth.login.passwordRequired') })
    .min(6, { message: t('auth.login.passwordTooShort') }),
})

const form = useForm({
  validationSchema: toTypedSchema(schema),
  initialValues: {
    account: '', // 将 email 的初始值设为空字符串
    password: '', // 将 password 的初始值设为空字符串
  },
})

const isLoading = ref(false)

const router = useRouter()


// 3. 修改 onValidSubmit 函数以使用 $fetch 和 try...catch
async function onValidSubmit(values: Record<string, any>) {
  console.log('Validation passed, submitting data:', values)
  isLoading.value = true

  try {
    // 使用 $fetch，这是在事件处理器中调用 API 的正确方式
    const response: any = await $fetch('/api/v1/auth/login', {
      method: 'POST',
      body: values, // 直接传递表单验证后的值
    })

    // 请求成功，$fetch 直接返回 JSON 响应体
    console.log('登录成功:', response)
    // 输出cookie
    console.log('Cookies:', document.cookie)

    // 使用 vue-sonner 的 toast 来显示成功信息，而不是 alert
    toast.success(t('auth.login.loginSuccess'), {
      description: t('auth.login.welcomeBack', { username: response.data.user.userInfo.USERNAME }),
    })

    // 登录成功后，使用 Nuxt 的 navigateTo 进行页面跳转
    await navigateTo('/')

  } catch (error: any) {
    // 如果 $fetch 失败 (API返回4xx或5xx), 它会抛出错误
    // 错误详情在 error.data 中
    console.error('登录失败:', error.data)

    // 使用 toast 显示错误信息
    toast.error(t('auth.login.loginFailed'), {
      description: error.data?.message || t('auth.login.unknownError'),
    })
  } finally {
    // 无论成功还是失败，最后都将加载状态设置为 false
    isLoading.value = false
  }
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
          <FormField v-slot="{ componentField }" name="account">
            <FormItem>
              <FormLabel>{{ $t('auth.login.account') }}</FormLabel>
              <FormControl>
                <Input type="account" :placeholder="$t('auth.login.accountPlaceholder')" v-bind="componentField" />
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
