<script setup lang="ts">
// 无页面布局
definePageMeta({
  layout: false
});

import { Button } from '@/components/ui/button';
import { useI18n } from 'vue-i18n';
import * as z from 'zod';
import { toTypedSchema } from '@vee-validate/zod';
import { useForm } from 'vee-validate';
import { toast } from 'vue-sonner';
import { usePreferenceStore } from '~/stores/user'; // 导入 store
import { v2Login } from '@/services';
// 从你的 UI 库中导入这些基础表单组件
import {
  FormControl,
  FormField,
  FormItem,
  FormLabel,
  FormMessage
} from '@/components/ui/form';
import { Input } from '@/components/ui/input'; // 导入 Input 组件
import { navigateTo } from '#app';

const { t } = useI18n();

const localePath = useLocalePath();

const preferenceStore = usePreferenceStore();

const description = t('auth.login.description');
const iframeHeight = '800px';
const containerClass = 'w-full h-full p-4 lg:p-0';

useHead({
  title: t('auth.login.title'),
  meta: [
    {
      name: 'description',
      content: description
    }
  ]
});

const loginFormSchema = z.object({
  account: z
    .string()
    .trim()
    .min(1, { message: t('auth.login.accountRequired') }),
  password: z
    .string()
    .min(1, { message: t('auth.login.passwordRequired') })
    .min(6, { message: t('auth.login.passwordTooShort') })
});
type LoginFormValues = z.infer<typeof loginFormSchema>;

const form = useForm<LoginFormValues>({
  validationSchema: toTypedSchema(loginFormSchema),
  initialValues: {
    account: '',
    password: ''
  }
});

const isLoading = ref(false);

async function onValidSubmit(
  values: LoginFormValues
): Promise<void> {
  isLoading.value = true;

  try {
    const response = await v2Login(values);
    preferenceStore.setCurrentUser(response.user);
    preferenceStore.setCurrentSession(response.tokens);
    toast(t('auth.login.successLogin'), {
      description:
        t('auth.login.welcomeBack') +
        ` ${response.user.display_name || '用户'}`
    });
    await navigateTo(localePath('/'));
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : t('auth.login.unknownError');
    console.error(t('auth.login.loginFailed'), error);
    toast.error(t('auth.login.loginFailed'), {
      description: message
    });
  } finally {
    isLoading.value = false;
  }
}

// 4. 创建最终的 onSubmit 函数，它会先验证再决定是否执行 onValidSubmit
const onSubmit = form.handleSubmit(onValidSubmit);
</script>

<template>
  <div
    class="w-full lg:grid lg:min-h-[600px] lg:grid-cols-2 xl:min-h-[800px]"
  >
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
        <form
          class="grid gap-4"
          :form="form"
          @submit="onSubmit"
        >
          <FormField
            v-slot="{ componentField }"
            name="account"
          >
            <FormItem>
              <FormLabel>{{
                $t('auth.login.account')
              }}</FormLabel>
              <FormControl>
                <Input
                  type="account"
                  :placeholder="
                    $t('auth.login.accountPlaceholder')
                  "
                  v-bind="componentField"
                />
              </FormControl>
              <FormMessage />
            </FormItem>
          </FormField>

          <FormField
            v-slot="{ componentField }"
            name="password"
          >
            <FormItem>
              <FormLabel>{{
                $t('auth.login.password')
              }}</FormLabel>
              <FormControl>
                <Input
                  type="password"
                  :placeholder="
                    $t('auth.login.passwordPlaceholder')
                  "
                  v-bind="componentField"
                />
              </FormControl>
              <FormMessage />
            </FormItem>
          </FormField>

          <div class="mt-4 text-center text-sm">
            {{ $t('auth.login.forgotPassword') }}
            <NuxtLink
              :to="$localePath('auth-forgot-password')"
              class="underline"
            >
              {{ $t('auth.login.resetPassword') }}
            </NuxtLink>
          </div>

          <Button type="submit" class="w-full">
            {{ $t('auth.login.loginButton') }}
          </Button>
        </form>
        <div class="mt-4 text-center text-sm">
          {{ $t('auth.login.noAccount') }}
          <NuxtLink
            :to="$localePath('/auth/sign-up')"
            class="underline"
          >
            {{ $t('auth.login.signUp') }}
          </NuxtLink>
        </div>
      </div>
    </div>
    <div class="hidden bg-muted lg:block">
      <img
        src="/placeholder.svg"
        alt="Image"
        width="1920"
        height="1080"
        class="h-full w-full object-cover dark:brightness-[0.2] dark:grayscale"
      />
    </div>
  </div>
</template>


