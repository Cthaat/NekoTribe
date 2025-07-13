<script lang="ts">
export const description =
  '一个双栏注册页面。左侧为注册表单，包含邮箱、用户名、密码、确认密码、显示名称、简介、所在地、手机号、生日、验证码和服务条款勾选。右侧为封面图片。'
export const iframeHeight = '800px'
export const containerClass = 'w-full h-full p-4 lg:p-0'
</script>

<script setup lang="ts">
import { ref } from 'vue'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Checkbox } from '@/components/ui/checkbox'

const form = ref({
  email: '',
  username: '',
  password: '',
  confirmPassword: '',
  displayName: '',
  bio: '',
  location: '',
  phone: '',
  birthDate: '',
  agreeToTerms: false,
  captcha: ''
})

function handleSubmit() {
  if (!form.value.agreeToTerms) {
    alert('请先同意服务条款')
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
          <h1 class="text-3xl font-bold">注册新账号</h1>
          <p class="text-balance text-muted-foreground">
            请填写以下信息以创建新账号
          </p>
        </div>
        <div class="grid gap-4">
          <!-- 邮箱地址单独一列 -->
          <div class="grid gap-2">
            <Label for="email">邮箱地址</Label>
            <Input id="email" v-model="form.email" type="email" placeholder="m@example.com" required />
          </div>
          <!-- 两列并排的表单项（用户名、显示名称、手机号、生日、所在地） -->
          <div class="grid grid-cols-2 gap-4">
            <div class="grid gap-2">
              <Label for="username">用户名</Label>
              <Input id="username" v-model="form.username" type="text" placeholder="3-20位字母数字下划线" required />
            </div>
            <div class="grid gap-2">
              <Label for="displayName">显示名称</Label>
              <Input id="displayName" v-model="form.displayName" type="text" placeholder="昵称" required />
            </div>
            <div class="grid gap-2">
              <Label for="phone">手机号</Label>
              <Input id="phone" v-model="form.phone" type="tel" placeholder="可选" />
            </div>
            <div class="grid gap-2">
              <Label for="birthDate">生日</Label>
              <Input id="birthDate" v-model="form.birthDate" type="date" placeholder="YYYY-MM-DD" />
            </div>
            <div class="grid gap-2">
              <Label for="location">所在地</Label>
              <Input id="location" v-model="form.location" type="text" placeholder="城市/地区" />
            </div>
          </div>
          <!-- 简介单独一列 -->
          <div class="grid gap-2">
            <Label for="bio">简介</Label>
            <Input id="bio" v-model="form.bio" type="text" placeholder="一句话介绍自己" />
          </div>
          <!-- 密码和确认密码单独一列 -->
          <div class="grid grid-cols-2 gap-4">
            <div class="grid gap-2">
              <Label for="password">密码</Label>
              <Input id="password" v-model="form.password" type="password" placeholder="8-32位，包含字母数字" required />
            </div>
            <div class="grid gap-2">
              <Label for="confirmPassword">确认密码</Label>
              <Input id="confirmPassword" v-model="form.confirmPassword" type="password" required />
            </div>
          </div>
          <!-- 验证码和服务条款并列 -->
          <div class="grid grid-cols-2 gap-4">
            <div class="grid gap-2">
              <Label for="captcha">验证码</Label>
              <Input id="captcha" v-model="form.captcha" type="text" placeholder="请输入验证码" required />
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
          <Button type="submit" class="w-full mt-2">注册</Button>
        </div>
        <div class="mt-4 text-center text-sm">
          已有账号？
          <a href="/auth/login" class="underline">立即登录</a>
        </div>
      </form>
    </div>
    <div class="hidden bg-muted lg:block">
      <img src="/placeholder.svg" alt="Image" width="1920" height="1080"
        class="h-full w-full object-cover dark:brightness-[0.2] dark:grayscale">
    </div>
  </div>
</template>
