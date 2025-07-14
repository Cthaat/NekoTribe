<script setup lang="ts">
import { ref, watch } from 'vue'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Checkbox } from '@/components/ui/checkbox'

// 日期选择器相关导入
import {
  DateFormatter,
  type DateValue,
  getLocalTimeZone,
} from '@internationalized/date'
import { CalendarIcon } from 'lucide-vue-next'
import { Calendar } from '@/components/ui/calendar'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { cn } from '@/lib/utils'
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

import { navigateTo } from '#app'

const { t } = useI18n()

const description = t('auth.signUp.description')
const iframeHeight = '800px'
const containerClass = 'w-full h-full p-4 lg:p-0'

useHead({
  title: t('auth.signUp.title'),
  meta: [
    {
      name: 'description',
      content: description
    }
  ],
})

// 更新 schema
const formSchema = toTypedSchema(
  z.object({
    email: z.string().email({ message: "请输入有效的邮箱地址" }),
    username: z.string().min(2, { message: "用户名至少需要2个字符" }),
    displayName: z.string().min(2, { message: "显示名称至少需要2个字符" }),
    phone: z.string().optional(),
    birthDate: z.any().optional(),
    location: z.string().optional(),
    bio: z.string().optional(),
    password: z.string().min(6, { message: "密码至少需要6个字符" }),
    confirmPassword: z.string().min(6, { message: "确认密码至少需要6个字符" }),
    captcha: z.string().optional(),
    // 简化 agreeToTerms 的验证逻辑
    agreeToTerms: z.boolean().refine((val) => val === true, {
      message: "您必须同意服务条款",
    }),
  }).refine(data => data.password === data.confirmPassword, {
    message: "两次输入的密码不一致",
    path: ["confirmPassword"], // 错误提示显示在确认密码字段
  })
)

// 创建表单实例
const form = useForm({
  validationSchema: formSchema,
  initialValues: {
    email: '',
    username: '',
    displayName: '',
    phone: '',
    // 将 birthDate 的初始值设为 `undefined` 或 `null`，而不是空字符串
    // 这与日历组件的期望值类型更匹配
    birthDate: undefined,
    location: '',
    bio: '',
    password: '',
    confirmPassword: '',
    captcha: '',
    agreeToTerms: false, // 默认同意服务条款
  },
})

const isLoading = ref(false)

const router = useRouter()

async function onValidSubmit(values: Record<string, any>) {
  isLoading.value = true

  try {
    // 1. 调用 API，等待它完成
    // const response: any = await apiFetch('/api/v1/auth/login', {
    //   method: 'POST',
    //   body: values,
    // })

    console.log('注册表单提交的值:', values);

    // 2. 成功后，唯一要做的就是导航！
    //    使用 await 确保导航被正确触发。
    //    让中间件和目标页面去担心登录状态。
    // console.log('注册成功，即将跳转...', response);
    await navigateTo('/auth/login');

  } catch (error: any) {
    // 错误处理逻辑保持不变
    console.error('注册失败:', error.data);
    toast.error('注册失败', {
      description: error.data?.message || '未知错误',
    })
  } finally {
    isLoading.value = false
  }
}

// 创建日期格式化实例，这部分是正确的
const df = new DateFormatter('zh-CN', {
  dateStyle: 'long',
})

// 4. 创建最终的 onSubmit 函数，它会先验证再决定是否执行 onValidSubmit
const onSubmit = form.handleSubmit(onValidSubmit)

// 手动管理 agreeToTerms 状态
const agreeToTermsValue = ref(false)

// 监听变化并同步到表单
watch(agreeToTermsValue, (newValue) => {
  console.log('同意服务条款状态变化:', newValue)
  form.setFieldValue('agreeToTerms', newValue)
})

// 添加一个点击处理函数来调试
const handleCheckboxChange = (checked: boolean) => {
  console.log('复选框点击事件触发:', checked)
  agreeToTermsValue.value = checked
}
</script>

<template>
  <div class="w-full lg:grid lg:min-h-[600px] lg:grid-cols-2 xl:min-h-[800px]">
    <div class="flex items-center justify-center py-12">
      <!-- 使用 vee-validate 的 handleSubmit 进行提交，它会先执行验证 -->
      <form class="mx-auto grid w-[400px] gap-6" @submit="onSubmit">
        <div class="grid gap-2 text-center">
          <h1 class="text-3xl font-bold">{{ $t('auth.signUp.signUpPrompt') }}</h1>
          <p class="text-balance text-muted-foreground">
            {{ $t('auth.signUp.signUpPromptDescription') }}
          </p>
        </div>

        <div class="grid gap-4">
          <!-- 邮箱地址 (单列) -->
          <FormField v-slot="{ componentField }" name="email">
            <FormItem>
              <FormLabel>{{ $t('auth.signUp.email') }}</FormLabel>
              <FormControl>
                <Input id="email" type="email" placeholder="m@example.com" v-bind="componentField" />
              </FormControl>
              <FormMessage />
            </FormItem>
          </FormField>

          <!-- 两列布局区域 -->
          <div class="grid grid-cols-2 gap-4">
            <!-- 用户名 -->
            <FormField v-slot="{ componentField }" name="username">
              <FormItem>
                <FormLabel>{{ $t('auth.signUp.username') }}</FormLabel>
                <FormControl>
                  <Input id="username" type="text" :placeholder="$t('auth.signUp.usernamePlaceholder')"
                    v-bind="componentField" />
                </FormControl>
                <FormMessage />
              </FormItem>
            </FormField>

            <!-- 显示名称 -->
            <FormField v-slot="{ componentField }" name="displayName">
              <FormItem>
                <FormLabel>{{ $t('auth.signUp.displayName') }}</FormLabel>
                <FormControl>
                  <Input id="displayName" type="text" :placeholder="$t('auth.signUp.displayNamePlaceholder')"
                    v-bind="componentField" />
                </FormControl>
                <FormMessage />
              </FormItem>
            </FormField>

            <!-- 手机号 -->
            <FormField v-slot="{ componentField }" name="phone">
              <FormItem>
                <FormLabel>{{ $t('auth.signUp.phone') }}</FormLabel>
                <FormControl>
                  <Input id="phone" type="tel" :placeholder="$t('auth.signUp.phonePlaceholder')"
                    v-bind="componentField" />
                </FormControl>
                <FormMessage />
              </FormItem>
            </FormField>

            <!-- 生日 (日历选择器) -->
            <FormField v-slot="{ componentField, value }" name="birthDate">
              <FormItem>
                <FormLabel>{{ $t('auth.signUp.birthDate') }}</FormLabel>
                <Popover>
                  <PopoverTrigger as-child>
                    <FormControl>
                      <!-- 
            这个按钮是用户看到的界面，它的作用是触发弹窗。
            它的文本内容会根据当前是否有值 (value) 来动态显示。
          -->
                      <Button variant="outline" :class="cn(
                        'w-full justify-start text-left font-normal',
                        !value && 'text-muted-foreground',
                      )">
                        <CalendarIcon class="mr-2 h-4 w-4" />
                        <!-- 
              三元表达式用于显示日期：
              - 如果 `value` 存在，就使用日期格式化工具 `df` 来显示。
              - 注意：日历组件返回的是一个特殊的日期对象，需要用 `.toDate(getLocalTimeZone())` 转换成标准 JS Date 对象才能格式化。
              - 如果 `value` 不存在，就显示占位符文本。
            -->
                        {{ value ? df.format(value.toDate(getLocalTimeZone())) : $t('auth.signUp.birthDatePlaceholder')
                        }}
                      </Button>
                    </FormControl>
                  </PopoverTrigger>
                  <PopoverContent class="w-auto p-0">
                    <!-- 
          这是核心部分：
          `v-bind="componentField"` 是一个语法糖，它将 vee-validate 的状态
          (包括 value, onBlur, onInput/onChange 事件) 自动绑定到 <Calendar> 组件上。
          这使得用户在日历中选择日期时，表单状态会自动更新。
        -->
                    <Calendar v-bind="componentField" initial-focus />
                  </PopoverContent>
                </Popover>
                <FormMessage />
              </FormItem>
            </FormField>

            <!-- 所在地 -->
            <FormField v-slot="{ componentField }" name="location">
              <FormItem>
                <FormLabel>{{ $t('auth.signUp.location') }}</FormLabel>
                <FormControl>
                  <Input id="location" type="text" :placeholder="$t('auth.signUp.locationPlaceholder')"
                    v-bind="componentField" />
                </FormControl>
                <FormMessage />
              </FormItem>
            </FormField>
          </div>

          <!-- 简介 (单列) -->
          <FormField v-slot="{ componentField }" name="bio">
            <FormItem>
              <FormLabel>{{ $t('auth.signUp.bio') }}</FormLabel>
              <FormControl>
                <Input id="bio" type="text" :placeholder="$t('auth.signUp.bioPlaceholder')" v-bind="componentField" />
              </FormControl>
              <FormMessage />
            </FormItem>
          </FormField>

          <!-- 密码区域 (两列) -->
          <div class="grid grid-cols-2 gap-4">
            <!-- 密码 -->
            <FormField v-slot="{ componentField }" name="password">
              <FormItem>
                <FormLabel>{{ $t('auth.signUp.password') }}</FormLabel>
                <FormControl>
                  <Input id="password" type="password" :placeholder="$t('auth.signUp.passwordPlaceholder')"
                    v-bind="componentField" />
                </FormControl>
                <FormMessage />
              </FormItem>
            </FormField>

            <!-- 确认密码 -->
            <FormField v-slot="{ componentField }" name="confirmPassword">
              <FormItem>
                <FormLabel>{{ $t('auth.signUp.confirmPassword') }}</FormLabel>
                <FormControl>
                  <Input id="confirmPassword" type="password"
                    :placeholder="$t('auth.signUp.confirmPasswordPlaceholder')" v-bind="componentField" />
                </FormControl>
                <FormMessage />
              </FormItem>
            </FormField>
          </div>

          <!-- 验证码和服务条款区域 (两列) -->
          <div class="grid grid-cols-2 gap-4 items-center">
            <!-- 验证码 -->
            <FormField v-slot="{ componentField }" name="captcha">
              <FormItem>
                <FormLabel>{{ $t('auth.signUp.captcha') }}</FormLabel>
                <FormControl>
                  <Input id="captcha" type="text" :placeholder="$t('auth.signUp.captchaPlaceholder')"
                    v-bind="componentField" />
                </FormControl>
                <FormMessage />
              </FormItem>
            </FormField>

            <!-- 服务条款 (复选框) -->
            <FormField name="agreeToTerms">
              <FormItem class="flex flex-row items-center gap-x-2 mt-6">
                <FormControl>
                  <!-- 使用原生的 v-model -->
                  <Checkbox v-model="agreeToTermsValue" />
                </FormControl>
                <div class="grid gap-1.5 leading-none">
                  <FormLabel
                    class="text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-70">
                    {{ $t('auth.signUp.agreeToTerms') }}
                    <a href="/terms" class="underline text-blue-600">{{ $t('auth.signUp.termsLink') }}</a>
                  </FormLabel>
                </div>
              </FormItem>
              <FormMessage />
            </FormField>
          </div>

          <Button type="submit" class="w-full mt-2">{{ $t('auth.signUp.signUpButton') }}</Button>
        </div>

        <div class="mt-4 text-center text-sm">
          {{ $t('auth.signUp.haveAccount') }}<br />
          <a href="/auth/login" class="underline">{{ $t('auth.signUp.loginPrompt') }}</a>
        </div>
      </form>
    </div>
    <div class="hidden bg-muted lg:block">
      <img src="/placeholder.svg" alt="Image" width="1920" height="1080"
        class="h-full w-full object-cover dark:brightness-[0.2] dark:grayscale">
    </div>
  </div>
</template>
