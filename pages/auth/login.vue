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
import { usePreferenceStore } from '~/stores/user'; // 导入 store
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

async function onValidSubmit(values: Record<string, any>) {
  isLoading.value = true

  try {
    // 1. 调用 API，等待它完成
    const response: any = await apiFetch('/api/v1/auth/login', {
      method: 'POST',
      body: values,
    })

    const preferenceStore = usePreferenceStore();

    // 登录成功后，调用新的 action
    preferenceStore.setAuthTokens(response.data.token, response.data.refreshToken);

    preferenceStore.updatePreference("user", response.data.user.userInfo);
    // 2. 成功后，唯一要做的就是导航！
    //    使用 await 确保导航被正确触发。
    //    让中间件和目标页面去担心登录状态。
    console.log('登录成功，即将跳转...', response);
    toast('登录成功,正在跳转到首页...', {
      description: '欢迎回来！',
    });
    await navigateTo('/');

  } catch (error: any) {
    // 错误处理逻辑保持不变
    console.error('登录失败:', error.data);
    toast.error('登录失败', {
      description: error.data?.message || '未知错误',
    })
  } finally {
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
