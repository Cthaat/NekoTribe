<script setup lang="ts">
import { Button } from '@/components/ui/button'
import { useI18n } from 'vue-i18n'
import { h } from 'vue'
import * as z from 'zod'
import { AutoForm } from '@/components/ui/auto-form'
import { toTypedSchema } from '@vee-validate/zod'
import { useForm } from 'vee-validate'
import { toast } from 'vue-sonner'
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


const schema = z.object({
  username: z.string(),
})

const form = useForm({
  validationSchema: toTypedSchema(schema),
})

function onSubmit(values: Record<string, any>) {
  toast({
    title: 'You submitted the following values:',
    description: h('pre', { class: 'mt-2 w-[340px] rounded-md bg-slate-950 p-4' }, h('code', { class: 'text-white' }, JSON.stringify(values, null, 2))),
  })
}
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
        <div class="grid gap-4">
          <div class="grid gap-2">
            <Label for="email">{{ $t('auth.login.email') }}</Label>
            <Input id="email" type="email" placeholder="m@example.com" required />
          </div>
          <div class="grid gap-2">
            <div class="flex items-center">
              <Label for="password">{{ $t('auth.login.password') }}</Label>
              <a href="/forgot-password" class="ml-auto inline-block text-sm underline">
                {{ $t('auth.login.forgotPassword') }}
              </a>
            </div>
            <Input id="password" type="password" required />
          </div>
          <Button type="submit" class="w-full">
            {{ $t('auth.login.loginButton') }}
          </Button>
        </div>
        <div class="mt-4 text-center text-sm">
          {{ $t('auth.login.noAccount') }}
          <a href="#" class="underline">
            Sign up
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
