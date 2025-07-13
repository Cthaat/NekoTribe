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

const form = ref({
  email: '',
  username: '',
  password: '',
  confirmPassword: '',
  displayName: '',
  bio: '',
  location: '',
  phone: '',
  birthDate: '', // 这里存储字符串
  agreeToTerms: false,
  captcha: ''
})

// 日期选择器相关
const df = new DateFormatter('zh-CN', {
  dateStyle: 'long',
})
const birthDateValue = ref<DateValue>()

// 监听日期选择器变化，更新 form.birthDate
watch(birthDateValue, (val) => {
  form.value.birthDate = val ? df.format(val.toDate(getLocalTimeZone())) : ''
})

function handleSubmit() {
  if (!form.value.agreeToTerms) {
    alert(t('auth.signUp.termsNotAgreed'))
    return
  }
  // 其他校验略
  // 提交到后端API
}
</script>

<template>
  <div class="w-full lg:grid lg:min-h-[600px] lg:grid-cols-2 xl:min-h-[800px]">
    <div class="flex items-center justify-center py-12">
      <form class="mx-auto grid w-[350px] gap-6" @submit.prevent="handleSubmit">
        <div class="grid gap-2 text-center">
          <h1 class="text-3xl font-bold">{{ $t('auth.signUp.signUpPrompt') }}</h1>
          <p class="text-balance text-muted-foreground">
            {{ $t('auth.signUp.signUpPromptDescription') }}
          </p>
        </div>
        <div class="grid gap-4">
          <!-- 邮箱地址单独一列 -->
          <div class="grid gap-2">
            <Label for="email">{{ $t('auth.signUp.email') }}</Label>
            <Input id="email" v-model="form.email" type="email" placeholder="m@example.com" required />
          </div>
          <!-- 两列并排的表单项（用户名、显示名称、手机号、生日、所在地） -->
          <div class="grid grid-cols-2 gap-4">
            <div class="grid gap-2">
              <Label for="username">{{ $t('auth.signUp.username') }}</Label>
              <Input id="username" v-model="form.username" type="text"
                placeholder="{{ $t('auth.signUp.usernamePlaceholder') }}" required />
            </div>
            <div class="grid gap-2">
              <Label for="displayName">{{ $t('auth.signUp.displayName') }}</Label>
              <Input id="displayName" v-model="form.displayName" type="text"
                placeholder="{{ $t('auth.signUp.displayNamePlaceholder') }}" required />
            </div>
            <div class="grid gap-2">
              <Label for="phone">{{ $t('auth.signUp.phone') }}</Label>
              <Input id="phone" v-model="form.phone" type="tel"
                placeholder="{{ $t('auth.signUp.phonePlaceholder') }}" />
            </div>
            <!-- 替换生日输入框为日期选择器 -->
            <div class="grid gap-2">
              <Label for="birthDate">{{ $t('auth.signUp.birthDate') }}</Label>
              <Popover>
                <PopoverTrigger as-child>
                  <Button variant="outline" :class="cn(
                    'w-full justify-start text-left font-normal',
                    !birthDateValue && 'text-muted-foreground',
                  )">
                    <CalendarIcon class="mr-2 h-4 w-4" />
                    {{ birthDateValue ? df.format(birthDateValue.toDate(getLocalTimeZone())) :
                      $t('auth.signUp.birthDatePlaceholder') }}
                  </Button>
                </PopoverTrigger>
                <PopoverContent class="w-auto p-0">
                  <Calendar v-model="birthDateValue" initial-focus />
                </PopoverContent>
              </Popover>
            </div>
            <div class="grid gap-2">
              <Label for="location">{{ $t('auth.signUp.location') }}</Label>
              <Input id="location" v-model="form.location" type="text"
                placeholder="{{ $t('auth.signUp.locationPlaceholder') }}" />
            </div>
          </div>
          <!-- 简介单独一列 -->
          <div class="grid gap-2">
            <Label for="bio">{{ $t('auth.signUp.bio') }}</Label>
            <Input id="bio" v-model="form.bio" type="text" placeholder="{{ $t('auth.signUp.bioPlaceholder') }}" />
          </div>
          <!-- 密码和确认密码单独一列 -->
          <div class="grid grid-cols-2 gap-4">
            <div class="grid gap-2">
              <Label for="password">{{ $t('auth.signUp.password') }}</Label>
              <Input id="password" v-model="form.password" type="password"
                placeholder="{{ $t('auth.signUp.passwordPlaceholder') }}" required />
            </div>
            <div class="grid gap-2">
              <Label for="confirmPassword">{{ $t('auth.signUp.confirmPassword') }}</Label>
              <Input id="confirmPassword" v-model="form.confirmPassword" type="password"
                placeholder="{{ $t('auth.signUp.confirmPasswordPlaceholder') }}" required />
            </div>
          </div>
          <!-- 验证码和服务条款并列 -->
          <div class="grid grid-cols-2 gap-4">
            <div class="grid gap-2">
              <Label for="captcha">{{ $t('auth.signUp.captcha') }}</Label>
              <Input id="captcha" v-model="form.captcha" type="text"
                placeholder="{{ $t('auth.signUp.captchaPlaceholder') }}" required />
            </div>
            <div class="flex items-center gap-x-2 mt-6">
              <Checkbox id="terms1" v-model:checked="form.agreeToTerms" />
              <div class="grid gap-1.5 leading-none">
                <label for="terms1"
                  class="text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-70">
                  我已阅读并同意 <a href="/terms" class="underline text-blue-600">服务条款</a>
                </label>
              </div>
            </div>
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
