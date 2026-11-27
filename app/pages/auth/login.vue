<script setup lang="ts">
definePageMeta({
  layout: false
});

import { onBeforeUnmount, onMounted, ref, shallowRef } from 'vue';
import AppButton from '@/components/app/AppButton.vue';
import ColorModeIcon from '@/components/ColorModeIcon.vue';
import LanguageTriggerIcon from '@/components/LanguageTriggerIcon.vue';
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  CardFooter
} from '@/components/ui/card';
import * as z from 'zod/v3';
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
import { normalizeGroupInviteCode } from '~/utils/group-invite';
import { cancelPasskeyPrompt, passkeyCancelled, supportsPasskeys } from '@/api/v2/passkeys';
import { v2LoginWithGitHub, v2LoginWithPasskey } from '@/services/auth';
import { openGitHubWindow } from '@/api/v2/github-oauth';

const { t } = useAppLocale();

const localePath = useLocalePath();
const route = useRoute();

const preferenceStore = usePreferenceStore();

const description = t('auth.login.description');

useHead({
  title: t('auth.login.title'),
  meta: [
    { name: 'referrer', content: 'no-referrer' },
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
    .trim()
    .min(1, { message: t('auth.login.passwordRequired') })
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
const passkeyAvailable = ref(false);
let passkeyPending = false;
let disposed = false;
const githubRequest = shallowRef<AbortController | null>(null);
onMounted(() => { passkeyAvailable.value = supportsPasskeys(); });
onBeforeUnmount(() => {
  disposed = true;
  if (passkeyPending) cancelPasskeyPrompt();
  githubRequest.value?.abort();
});

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
  const invite = normalizeGroupInviteCode(route.query.code);
  await navigateTo(localePath(invite ? `/groups/invite/${invite}` : '/'));
}

async function onValidSubmit(
  values: LoginFormValues
): Promise<void> {
  if (isLoading.value) return;
  isLoading.value = true;
  let revision = preferenceStore.authRevision();

  try {
    const request = v2Login({
      ...values,
      rememberMe: trustDevice.value
    });
    revision = preferenceStore.authRevision();
    const response = await request;
    if (!preferenceStore.isAuthCurrent(revision)) return;
    if (isTwoFactorChallenge(response)) {
      twoFactorChallenge.value = response;
      twoFactorCode.value = '';
      toast.info(t('auth.login.twoFactorRequired'));
      return;
    }
    await completeLogin(response);
  } catch (error) {
    if (!preferenceStore.isAuthCurrent(revision)) return;
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
  if (isLoading.value) return;
  const challenge = twoFactorChallenge.value;
  const code = twoFactorCode.value.trim();
  if (!challenge || !code) {
    toast.error(t('auth.login.twoFactorCodeRequired'));
    return;
  }

  isLoading.value = true;
  let revision = preferenceStore.authRevision();
  try {
    const request = v2CompleteTwoFactorLogin({
      challengeId: challenge.challengeId,
      code
    });
    revision = preferenceStore.authRevision();
    const response = await request;
    if (!preferenceStore.isAuthCurrent(revision)) return;
    await completeLogin(response);
  } catch (error) {
    if (!preferenceStore.isAuthCurrent(revision)) return;
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

async function loginWithPasskey(): Promise<void> {
  if (isLoading.value || !passkeyAvailable.value || twoFactorChallenge.value) return;
  isLoading.value = true;
  passkeyPending = true;
  const app = useNuxtApp();
  let revision = preferenceStore.authRevision();
  try {
    const login = v2LoginWithPasskey(trustDevice.value, () => !disposed);
    revision = preferenceStore.authRevision();
    const response = await login;
    if (disposed || !preferenceStore.isAuthCurrent(revision)) return;
    if (isTwoFactorChallenge(response)) {
      twoFactorChallenge.value = response;
      twoFactorCode.value = '';
      toast.info(t('auth.login.twoFactorRequired'));
      return;
    }
    await app.runWithContext(() => completeLogin(response));
  } catch (error) {
    if (disposed || passkeyCancelled(error) || !preferenceStore.isAuthCurrent(revision)) return;
    const unavailable = error && typeof error === 'object' && 'statusCode' in error && error.statusCode === 503;
    toast.error(t(unavailable ? 'passkeys.unavailable' : 'passkeys.signInFailed'));
  } finally { isLoading.value = false; passkeyPending = false; }
}

async function loginWithGitHub(): Promise<void> {
  if (isLoading.value || twoFactorChallenge.value) return;
  let popup: ReturnType<typeof openGitHubWindow>;
  try { popup = openGitHubWindow(); }
  catch { toast.error(t('githubOAuth.popupBlocked')); return; }

  const request = new AbortController();
  githubRequest.value = request;
  isLoading.value = true;
  const app = useNuxtApp();
  let revision = preferenceStore.authRevision();
  try {
    const pending = v2LoginWithGitHub({ signal: request.signal, current: () => !disposed, open: popup.open }, trustDevice.value);
    revision = preferenceStore.authRevision();
    const response = await pending;
    if (disposed || request.signal.aborted || !preferenceStore.isAuthCurrent(revision)) return;
    if (isTwoFactorChallenge(response)) {
      twoFactorChallenge.value = response;
      twoFactorCode.value = '';
      toast.info(t('auth.login.twoFactorRequired'));
      return;
    }
    await app.runWithContext(() => completeLogin(response));
  } catch (error) {
    if (disposed || request.signal.aborted || !preferenceStore.isAuthCurrent(revision)) return;
    const unavailable = error && typeof error === 'object' && 'statusCode' in error && error.statusCode === 503;
    toast.error(t(unavailable ? 'githubOAuth.unavailable' : 'githubOAuth.signInFailed'));
  } finally { popup.close(); githubRequest.value = null; isLoading.value = false; }
}

const onSubmit = form.handleSubmit(onValidSubmit);
</script>

<template>
  <div
    class="relative grid min-h-svh w-full overflow-x-clip bg-background lg:grid-cols-2"
  >
    <!-- Left: Form column -->
    <div class="flex min-w-0 flex-col gap-4 p-4 sm:p-6 md:p-10">
      <div class="flex items-center justify-between gap-2">
        <NuxtLink
          :to="localePath('/')"
          class="flex items-center gap-2 font-medium"
        >
          <div
            class="flex h-8 w-8 items-center justify-center rounded-full bg-primary text-primary-foreground"
          >
            <Cat class="size-4" />
          </div>
          <span class="text-sm font-semibold">{{ t('app.brand.name') }}</span>
        </NuxtLink>
        <div class="flex shrink-0 items-center gap-1.5">
          <LanguageTriggerIcon />
          <ColorModeIcon />
        </div>
      </div>

      <div class="flex min-w-0 flex-1 items-center justify-center">
        <div class="w-full max-w-md">
          <Card class="bento-card p-6 sm:p-8">
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
                        class="h-11 rounded-[14px] border-0 bg-secondary shadow-none dark:bg-secondary"
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
                          class="h-11 rounded-[14px] border-0 bg-secondary pr-10 shadow-none dark:bg-secondary"
                          v-bind="componentField"
                        />
                        <button
                          type="button"
                          :aria-label="t('common.togglePasswordVisibility')"
                          :aria-pressed="showPassword"
                          class="absolute right-2.5 top-1/2 -translate-y-1/2 rounded-full p-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
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
                    :model-value="trustDevice"
                    :disabled="isLoading"
                    @update:model-value="trustDevice = $event === true"
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
                    class="bento-tile grid gap-2 p-4"
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
                      class="h-11 rounded-[14px] border-0 bg-card text-center font-mono tracking-widest shadow-none dark:bg-card"
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
                  class="h-11 w-full rounded-full font-semibold"
                  :loading="isLoading"
                  :loading-label="t('auth.login.loginButton')"
                >
                  {{ t('auth.login.loginButton') }}
                </AppButton>
                <AppButton
                  v-else
                  type="button"
                  class="h-11 w-full rounded-full font-semibold"
                  :loading="isLoading"
                  :loading-label="t('auth.login.twoFactorVerify')"
                  @click="handleTwoFactorSubmit"
                >
                  {{ t('auth.login.twoFactorVerify') }}
                </AppButton>

                <AppButton v-if="passkeyAvailable && !twoFactorChallenge" type="button" variant="secondary"
                  class="h-11 w-full rounded-full font-medium" :disabled="isLoading" @click="loginWithPasskey">
                  {{ t('passkeys.signIn') }}
                </AppButton>

                <AppButton v-if="!twoFactorChallenge" type="button" variant="secondary" class="h-11 w-full rounded-full font-medium"
                  :disabled="isLoading" @click="loginWithGitHub">
                  {{ t('githubOAuth.signIn') }}
                </AppButton>
                <div v-if="githubRequest" class="flex items-center justify-between gap-3 text-sm text-muted-foreground">
                  <p role="status">{{ t('githubOAuth.waiting') }}</p>
                  <button type="button" class="underline" @click="githubRequest.abort()">{{ t('common.cancel') }}</button>
                </div>

                <div
                  class="after:border-border relative text-center text-xs after:absolute after:inset-0 after:top-1/2 after:z-0 after:flex after:items-center after:border-t"
                >
                  <span class="bg-card text-muted-foreground relative z-10 px-2">
                    {{ t('auth.login.noAccount') }}
                  </span>
                </div>

                <NuxtLink
                  :to="localePath('/auth/sign-up')"
                  class="pressable inline-flex h-11 w-full items-center justify-center rounded-full bg-secondary px-4 py-2 text-sm font-medium text-foreground transition-colors hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none"
                >
                  {{ t('auth.login.signUp') }}
                </NuxtLink>
              </form>
            </CardContent>
          </Card>
        </div>
      </div>
    </div>

    <!-- Right: Subtle grid quiet brand column -->
    <div
      class="relative hidden overflow-hidden bg-secondary/70 bg-subtle-grid p-10 lg:flex lg:items-center lg:justify-center"
    >
      <div
        class="bento-card flex size-40 items-center justify-center"
      >
        <div
          class="flex size-24 items-center justify-center rounded-[20px] bg-[var(--primary-soft)]"
        >
          <Cat class="size-12 text-primary" />
        </div>
      </div>
      <!-- Brand mark in corner -->
      <div class="absolute bottom-8 left-8 right-8 z-10">
        <div class="liquid-glass-popover rounded-[26px] p-6">
          <blockquote class="space-y-2">
            <p class="text-[17px] font-medium leading-[1.62] text-foreground/90">
              &ldquo;{{ t('app.brand.tagline') }}&rdquo;
            </p>
            <footer class="text-sm text-[var(--ink-tertiary)]">
              — {{ t('app.brand.name') }}
            </footer>
          </blockquote>
        </div>
      </div>
    </div>
  </div>
</template>
