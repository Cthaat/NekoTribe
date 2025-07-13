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
const errorMessage = ref<string | null>(null)

const router = useRouter()

// 3. 将你的提交逻辑放入一个只在验证成功时才调用的函数中
async function onValidSubmit(values: Record<string, any>) {
  console.log('Validation passed, submitting data:', values)
  toast({
    title: 'You submitted the following values:',
    description: h('pre', { class: 'mt-2 w-[340px] rounded-md bg-slate-950 p-4' }, h('code', { class: 'text-white' }, JSON.stringify(values, null, 2))),
  })
  // 在这里执行页面跳转或API请求


  try {
    // 2. 调用后端 API
    // 我们使用 `$fetch`，因为它非常适合这种事件驱动的请求
    interface LoginResponse {
      success: boolean
      message?: string
      data?: {
        user?: {
          userInfo: any
        }
      }
    }
    const response = await $fetch<LoginResponse>('/api/login', { // 你的 API 端点
      method: 'POST',
      body: {
        account: values.account, // 使用表单验证后的值
        password: values.password,
      },
    })

    // 3. 处理成功响应
    if (response.success && response.data?.user) {
      console.log('登录成功!', response)

      // 将后端返回的用户信息存入 Pinia Store
      // userStore.setUser(response.data.user.userInfo)

      // 登录成功后，重定向到用户首页或仪表盘
      await router.push('/') // 或者 '/dashboard'
    } else {
      // 如果后端返回的 success 是 false，也作为错误处理
      throw new Error(response.message || '登录失败，但未返回明确错误信息')
    }

  } catch (error: any) {
    // 4. 处理错误响应
    // Nuxt 的 $fetch 会将非 2xx 的响应抛出为错误
    // 错误信息在 `error.data` 中
    console.error('登录失败:', error.data)
    errorMessage.value = error.data?.message || '发生了未知错误，请稍后重试。'

  } finally {
    // 5. 结束加载状态
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
