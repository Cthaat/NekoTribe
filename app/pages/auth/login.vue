<script setup lang="ts">
definePageMeta({
  layout: false
});

import { ref } from 'vue';
import AppButton from '@/components/app/AppButton.vue';
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  CardFooter
} from '@/components/ui/card';
import * as z from 'zod';
import { toTypedSchema } from '@vee-validate/zod';
import { useForm } from 'vee-validate';
import { toast } from 'vue-sonner';
import { usePreferenceStore } from '~/stores/user';
import {
  v2CompleteTwoFactorLogin,
  v2Login
} from '@/services';
import type {
  LoginResultVM,
  LoginVM,
  TwoFactorLoginChallengeVM
} from '@/types/auth';
import {
  FormControl,
  FormField,
  FormItem,
  FormLabel,
  FormMessage
} from '@/components/ui/form';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Checkbox } from '@/components/ui/checkbox';
import { Separator } from '@/components/ui/separator';
import { Cat, Eye, EyeOff, ShieldCheck } from 'lucide-vue-next';
import { navigateTo } from '#app';

const { t } = useAppLocale();

const localePath = useLocalePath();

const preferenceStore = usePreferenceStore();

const description = t('auth.login.description');

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
const showPassword = ref(false);
const twoFactorChallenge =
  ref<TwoFactorLoginChallengeVM | null>(null);
const twoFactorCode = ref('');
const trustDevice = ref(false);

function isTwoFactorChallenge(
  response: LoginResultVM
): response is TwoFactorLoginChallengeVM {
  return 'twoFactorRequired' in response && response.twoFactorRequired;
}

async function completeLogin(response: LoginVM): Promise<void> {
  preferenceStore.setCurrentUser(response.user);
  preferenceStore.setCurrentSession(response.tokens);
  toast(t('auth.login.successLogin'), {
    description:
      t('auth.login.welcomeBack') +
      ` ${response.user.name || t('nav.user.fallbackName')}`
  });
  await navigateTo(localePath('/'));
}

async function onValidSubmit(
  values: LoginFormValues
): Promise<void> {
  isLoading.value = true;

  try {
    const response = await v2Login({
      ...values,
      rememberMe: trustDevice.value
    });
    if (isTwoFactorChallenge(response)) {
      twoFactorChallenge.value = response;
      twoFactorCode.value = '';
      toast.info(t('auth.login.twoFactorRequired'));
      return;
    }
    await completeLogin(response);
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : t('auth.login.unknownError');
    toast.error(t('auth.login.loginFailed'), {
      description: message
    });
  } finally {
    isLoading.value = false;
  }
}

async function handleTwoFactorSubmit(): Promise<void> {
  const challenge = twoFactorChallenge.value;
  const code = twoFactorCode.value.trim();
  if (!challenge || !code) {
    toast.error(t('auth.login.twoFactorCodeRequired'));
    return;
  }

  isLoading.value = true;
  try {
    const response = await v2CompleteTwoFactorLogin({
      challengeId: challenge.challengeId,
      code
    });
    await completeLogin(response);
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : t('auth.login.unknownError');
    toast.error(t('auth.login.twoFactorFailed'), {
      description: message
    });
  } finally {
    isLoading.value = false;
  }
}

const onSubmit = form.handleSubmit(onValidSubmit);
</script>

<template>
  <div
    class="relative grid min-h-svh w-full lg:grid-cols-2"
  >
    <!-- Left: Form column -->
    <div class="flex flex-col gap-4 p-6 md:p-10">
      <div class="flex justify-center gap-2 md:justify-start">
        <NuxtLink
          :to="localePath('/')"
          class="flex items-center gap-2 font-medium"
        >
          <div
            class="flex h-7 w-7 items-center justify-center rounded-md bg-primary text-primary-foreground"
          >
            <Cat class="size-4" />
          </div>
          <span class="text-sm">{{ t('app.brand.name') }}</span>
        </NuxtLink>
      </div>

      <div class="flex flex-1 items-center justify-center">
        <div class="w-full max-w-sm">
          <Card class="border-none shadow-none">
            <CardHeader class="space-y-1 px-0 text-center">
              <CardTitle
                class="text-2xl font-semibold tracking-tight"
              >
                {{ t('auth.login.title') }}
              </CardTitle>
              <CardDescription class="text-balance">
                {{ t('auth.login.loginPrompt') }}
              </CardDescription>
            </CardHeader>

            <CardContent class="px-0">
              <form
                class="grid gap-5"
                @submit.prevent="onSubmit"
              >
                <FormField
                  v-slot="{ componentField }"
                  name="account"
                >
                  <FormItem>
                    <FormLabel>{{
                      t('auth.login.account')
                    }}</FormLabel>
                    <FormControl>
                      <Input
                        type="text"
                        autocomplete="username"
                        :disabled="isLoading"
                        :placeholder="
                          t('auth.login.accountPlaceholder')
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
                    <div class="flex items-center justify-between">
                      <FormLabel>{{
                        t('auth.login.password')
                      }}</FormLabel>
                      <NuxtLink
                        :to="localePath('auth-forgot-password')"
                        class="text-xs text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
                      >
                        {{ t('auth.login.resetPassword') }}
                      </NuxtLink>
                    </div>
                    <FormControl>
                      <div class="relative">
                        <Input
                          :type="showPassword ? 'text' : 'password'"
                          autocomplete="current-password"
                          :disabled="isLoading"
                          :placeholder="
                            t('auth.login.passwordPlaceholder')
                          "
                          class="pr-10"
                          v-bind="componentField"
                        />
                        <button
                          type="button"
                          tabindex="-1"
                          class="absolute right-2 top-1/2 -translate-y-1/2 rounded-md p-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                          @click="showPassword = !showPassword"
                        >
                          <component
                            :is="showPassword ? EyeOff : Eye"
                            class="h-4 w-4"
                          />
                        </button>
                      </div>
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                </FormField>

                <div class="flex items-center gap-2.5">
                  <Checkbox
                    id="trust-device"
                    :checked="trustDevice"
                    :disabled="isLoading"
                    @update:checked="trustDevice = $event === true"
                  />
                  <Label
                    for="trust-device"
                    class="cursor-pointer text-sm font-normal leading-none text-muted-foreground"
                  >
                    {{ t('auth.login.trustDevice') }}
                  </Label>
                </div>

                <Transition
                  enter-active-class="transition duration-200 ease-out"
                  enter-from-class="opacity-0 -translate-y-1"
                  enter-to-class="opacity-100 translate-y-0"
                  leave-active-class="transition duration-150 ease-in"
                  leave-from-class="opacity-100"
                  leave-to-class="opacity-0"
                >
                  <div
                    v-if="twoFactorChallenge"
                    class="grid gap-2 rounded-lg border bg-muted/30 p-4"
                  >
                    <div class="flex items-center gap-2 text-sm font-medium">
                      <ShieldCheck class="h-4 w-4 text-primary" />
                      {{ t('auth.login.twoFactorCode') }}
                    </div>
                    <Input
                      id="two-factor-code"
                      v-model="twoFactorCode"
                      :disabled="isLoading"
                      inputmode="numeric"
                      autocomplete="one-time-code"
                      :placeholder="t('auth.login.twoFactorCodePlaceholder')"
                      class="tracking-widest text-center font-mono"
                      @keydown.enter.prevent="handleTwoFactorSubmit"
                    />
                    <p class="text-xs text-muted-foreground">
                      {{ t('auth.login.twoFactorHint') }}
                    </p>
                  </div>
                </Transition>

                <AppButton
                  v-if="!twoFactorChallenge"
                  type="submit"
                  class="w-full"
                  :loading="isLoading"
                  :loading-label="t('auth.login.loginButton')"
                >
                  {{ t('auth.login.loginButton') }}
                </AppButton>
                <AppButton
                  v-else
                  type="button"
                  class="w-full"
                  :loading="isLoading"
                  :loading-label="t('auth.login.twoFactorVerify')"
                  @click="handleTwoFactorSubmit"
                >
                  {{ t('auth.login.twoFactorVerify') }}
                </AppButton>

                <div
                  class="after:border-border relative text-center text-xs after:absolute after:inset-0 after:top-1/2 after:z-0 after:flex after:items-center after:border-t"
                >
                  <span class="bg-background text-muted-foreground relative z-10 px-2">
                    {{ t('auth.login.noAccount') }}
                  </span>
                </div>

                <NuxtLink
                  :to="localePath('/auth/sign-up')"
                  class="inline-flex h-9 w-full items-center justify-center rounded-md border border-input bg-background px-4 py-2 text-sm font-medium shadow-xs transition-colors hover:bg-accent hover:text-accent-foreground"
                >
                  {{ t('auth.login.signUp') }}
                </NuxtLink>
              </form>
            </CardContent>
          </Card>
        </div>
      </div>
    </div>

    <!-- Right: Decorative column -->
    <div class="bg-muted relative hidden lg:block overflow-hidden">
      <img
        src="/placeholder.svg"
        :alt="t('auth.login.coverImageAlt')"
        width="1920"
        height="1080"
        class="absolute inset-0 h-full w-full object-cover dark:brightness-[0.2] dark:grayscale"
      />
      <!-- Soft overlay gradient -->
      <div
        class="pointer-events-none absolute inset-0 bg-gradient-to-tr from-background/60 via-transparent to-background/30"
      />
      <!-- Brand mark in corner -->
      <div class="absolute bottom-8 left-8 right-8 z-10">
        <blockquote class="space-y-2">
          <p class="text-lg font-medium leading-relaxed text-foreground/90">
            &ldquo;{{ t('app.brand.tagline') }}&rdquo;
          </p>
          <footer class="text-sm text-muted-foreground">
            — {{ t('app.brand.name') }}
          </footer>
        </blockquote>
      </div>
    </div>
  </div>
</template>
