<script setup lang="ts">
definePageMeta({
  layout: false
});

import { toTypedSchema } from '@vee-validate/zod';
import { useForm } from 'vee-validate';
import { ref, watch, onUnmounted } from 'vue';
import { otpRetryDelay } from '~/utils/otpRetryAfter';
import * as z from 'zod/v3';
import {
  Cat,
  Eye,
  EyeOff,
  KeyRound,
  ShieldCheck
} from 'lucide-vue-next';
import {
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage
} from '@/components/ui/form';
import {
  PinInput,
  PinInputGroup,
  PinInputSlot
} from '@/components/ui/pin-input';
import AppButton from '@/components/app/AppButton.vue';
import ColorModeIcon from '@/components/ColorModeIcon.vue';
import LanguageTriggerIcon from '@/components/LanguageTriggerIcon.vue';
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle
} from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { toast } from 'vue-sonner';
import {
  v2CreateOtp,
  v2PasswordReset
} from '@/services';
import { usePreferenceStore } from '~/stores/user';
import { navigateTo } from '#app';

const preferenceStore = usePreferenceStore();

const { t } = useAppLocale();

const localePath = useLocalePath();

const description = t('auth.forgotPassword.forgotPasswordPrompt');
useHead({
  title: t('auth.forgotPassword.title'),
  meta: [
    {
      name: 'description',
      content: description
    }
  ]
});

const value = ref<string[]>([]);
const verificationId = ref('');
const verificationAccount = ref('');
let otpRequestVersion = 0;
let otpDisposed = false;

const isConfirmPasswordVisible = ref(false);
const isPasswordVisible = ref(false);
const isLoading = ref(false);

const isCaptchaSending = ref(false);
const countdown = ref(60);
let timer: ReturnType<typeof setInterval> | null = null;
const email = ref('');

function resetVerification(): void {
  otpRequestVersion++;
  verificationId.value = '';
  verificationAccount.value = '';
  value.value = [];
  isCaptchaSending.value = false;
  if (timer) clearInterval(timer);
  timer = null;
}

function isOtpCurrent(version: number, account: string): boolean {
  return !otpDisposed && version === otpRequestVersion && email.value.trim() === account;
}

watch(() => email.value.trim(), resetVerification, { flush: 'sync' });
onUnmounted(() => { otpDisposed = true; resetVerification(); });

function beginOtpCooldown(seconds: number, version: number, account: string): void {
  const endsAt = Date.now() + seconds * 1000;
  countdown.value = seconds;
  timer = setInterval(() => {
    if (!isOtpCurrent(version, account)) {
      return;
    }
    countdown.value = Math.max(0, Math.ceil((endsAt - Date.now()) / 1000));
    if (countdown.value === 0) {
      isCaptchaSending.value = false;
      if (timer) clearInterval(timer);
      timer = null;
    }
  }, 1000);
}

async function sendCaptcha(): Promise<void> {
  if (isCaptchaSending.value || isLoading.value || otpDisposed) return;
  const account = email.value.trim();
  if (!account) return;
  if (!z.string().email().safeParse(account).success) {
    toast.error(t('auth.forgotPassword.emailInvalid'));
    return;
  }
  const previous = { id: verificationId.value, account: verificationAccount.value, code: [...value.value] };
  resetVerification();
  const version = otpRequestVersion;
  isCaptchaSending.value = true;
  countdown.value = 60;

  try {
    const response = await v2CreateOtp({
      account,
      type: 'password_reset',
      channel: 'email'
    });
    if (!isOtpCurrent(version, account)) return;
    if (response.account !== account || !response.verificationId?.trim()) throw new Error(t('auth.forgotPassword.captchaSendError'));
    verificationId.value = response.verificationId;
    verificationAccount.value = account;

    toast.success(t('auth.forgotPassword.captchaSent'), {
      description: t(
        'auth.forgotPassword.captchaSentDescription'
      )
    });

    beginOtpCooldown(60, version, account);
  } catch (error) {
    if (!isOtpCurrent(version, account)) return;
    const retry = otpRetryDelay(error);
    if (retry !== null) {
      if (previous.id && previous.account === account) {
        verificationId.value = previous.id;
        verificationAccount.value = previous.account;
        value.value = previous.code;
      }
      beginOtpCooldown(retry, version, account);
    }
    const message =
      error instanceof Error
        ? error.message
        : t('auth.forgotPassword.unknownError');
    toast.error(t('auth.forgotPassword.captchaSendError'), {
      description: message
    });
  } finally {
    if (isOtpCurrent(version, account) && !timer) isCaptchaSending.value = false;
  }
}

const forgotPasswordFormSchema = z
  .object({
    email: z
      .string()
      .trim()
      .email(t('auth.forgotPassword.emailInvalid')),
    newPassword: z.string().trim().min(6, {
      message: t('auth.forgotPassword.passwordTooShort')
    }),
    confirmPassword: z.string().trim().min(6, {
      message: t('auth.forgotPassword.passwordTooShort')
    }),
    captcha: z.string()
  })
  .refine(
    data => data.newPassword === data.confirmPassword,
    {
      message: t('auth.forgotPassword.passwordMismatch'),
      path: ['confirmPassword']
    }
  );
type ForgotPasswordFormValues = z.infer<
  typeof forgotPasswordFormSchema
>;

const { handleSubmit } = useForm<ForgotPasswordFormValues>({
  validationSchema: toTypedSchema(forgotPasswordFormSchema),
  initialValues: {
    email: '',
    newPassword: '',
    confirmPassword: '',
    captcha: ''
  }
});

const onSubmit = handleSubmit(
  async (values: ForgotPasswordFormValues): Promise<void> => {
    if (isLoading.value || otpDisposed) return;
    const authRevision = preferenceStore.authRevision();
    const otpVersion = otpRequestVersion, account = values.email.trim();
    isLoading.value = true;
    let resetSucceeded = false;
    try {
      if (!verificationId.value || verificationAccount.value !== values.email.trim()) {
        throw new Error(
          t('auth.forgotPassword.captchaSendError')
        );
      }
      await v2PasswordReset({
        email: values.email,
        verificationId: verificationId.value,
        code: value.value.join(''),
        newPassword: values.newPassword
      });
      resetSucceeded = true;
      if (!isOtpCurrent(otpVersion, account) || !preferenceStore.isAuthCurrent(authRevision)) return;
      toast.success(
        t('auth.forgotPassword.resetPasswordSuccess'),
        {
          description: t(
            'auth.forgotPassword.resetPasswordSuccessDescription'
          )
        }
      );
    } catch (error) {
      if (!isOtpCurrent(otpVersion, account) || !preferenceStore.isAuthCurrent(authRevision)) return;
      const message =
        error instanceof Error
          ? error.message
          : t('auth.forgotPassword.unknownError');
      toast.error(
        t('auth.forgotPassword.resetPasswordError'),
        {
          description: message
        }
      );
    } finally {
      try {
        if (!resetSucceeded || !isOtpCurrent(otpVersion, account)) return;
        const result = await preferenceStore.logoutCurrentSession(authRevision);
        if (!result || !preferenceStore.isAuthCurrent(result.revision)) return;
        if (!result.ok) throw result.error;
        setTimeout(() => {
          if (preferenceStore.isAuthCurrent(result.revision)) {
            navigateTo(localePath('auth-login'));
          }
        }, 2000);
      } catch {
        toast.error(
          t('account.security.securityPage.password.logoutError')
        );
      } finally {
        isLoading.value = false;
      }
    }
  }
);
</script>

<template>
  <div class="relative grid min-h-svh w-full overflow-x-clip bg-background lg:grid-cols-2">
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
              <div
                class="mx-auto mb-2 flex h-12 w-12 items-center justify-center rounded-full bg-[var(--primary-soft)]"
              >
                <KeyRound class="h-5 w-5 text-primary" />
              </div>
              <CardTitle
                class="text-2xl font-semibold tracking-tight"
              >
                {{ t('auth.forgotPassword.title') }}
              </CardTitle>
              <CardDescription class="text-balance">
                {{ t('auth.forgotPassword.forgotPasswordPrompt') }}
              </CardDescription>
            </CardHeader>

            <CardContent class="px-0">
              <form class="grid gap-5" @submit="onSubmit">
                <FormField
                  v-slot="{ componentField }"
                  name="email"
                >
                  <FormItem>
                    <FormLabel>{{
                      t('auth.forgotPassword.email')
                    }}</FormLabel>
                    <FormControl>
                      <Input
                        type="text"
                        autocomplete="email"
                        :disabled="isLoading"
                        :placeholder="
                          t('auth.forgotPassword.emailPlaceholder')
                        "
                        class="h-11 rounded-[14px] border-0 bg-secondary shadow-none dark:bg-secondary"
                        v-bind="componentField"
                        v-model="email"
                      />
                    </FormControl>
                    <FormDescription class="text-[11px]">
                      {{
                        t('auth.forgotPassword.emailDescription')
                      }}
                    </FormDescription>
                    <FormMessage />
                  </FormItem>
                </FormField>

                <FormField
                  v-slot="{ componentField }"
                  name="newPassword"
                >
                  <FormItem>
                    <FormLabel>{{
                      t('auth.forgotPassword.newPassword')
                    }}</FormLabel>
                    <FormControl>
                      <div class="relative">
                        <Input
                          :type="
                            isPasswordVisible ? 'text' : 'password'
                          "
                          autocomplete="new-password"
                          :disabled="isLoading"
                          :placeholder="
                            t(
                              'auth.forgotPassword.newPasswordPlaceholder'
                            )
                          "
                          class="h-11 rounded-[14px] border-0 bg-secondary pr-10 shadow-none dark:bg-secondary"
                          v-bind="componentField"
                        />
                        <button
                          type="button"
                          :aria-label="t('common.togglePasswordVisibility')"
                          :aria-pressed="isPasswordVisible"
                          class="absolute right-2.5 top-1/2 -translate-y-1/2 rounded-full p-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                          @click="
                            isPasswordVisible = !isPasswordVisible
                          "
                        >
                          <component
                            :is="isPasswordVisible ? EyeOff : Eye"
                            class="h-4 w-4"
                          />
                        </button>
                      </div>
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                </FormField>

                <FormField
                  v-slot="{ componentField }"
                  name="confirmPassword"
                >
                  <FormItem>
                    <FormLabel>{{
                      t('auth.forgotPassword.confirmPassword')
                    }}</FormLabel>
                    <FormControl>
                      <div class="relative">
                        <Input
                          :type="
                            isConfirmPasswordVisible
                              ? 'text'
                              : 'password'
                          "
                          autocomplete="new-password"
                          :disabled="isLoading"
                          :placeholder="
                            t(
                              'auth.forgotPassword.confirmPasswordPlaceholder'
                            )
                          "
                          class="h-11 rounded-[14px] border-0 bg-secondary pr-10 shadow-none dark:bg-secondary"
                          v-bind="componentField"
                        />
                        <button
                          type="button"
                          :aria-label="t('common.togglePasswordVisibility')"
                          :aria-pressed="isConfirmPasswordVisible"
                          class="absolute right-2.5 top-1/2 -translate-y-1/2 rounded-full p-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                          @click="
                            isConfirmPasswordVisible =
                              !isConfirmPasswordVisible
                          "
                        >
                          <component
                            :is="
                              isConfirmPasswordVisible ? EyeOff : Eye
                            "
                            class="h-4 w-4"
                          />
                        </button>
                      </div>
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                </FormField>

                <FormField
                  v-slot="{ componentField }"
                  name="captcha"
                >
                  <FormItem>
                    <div
                      class="bento-tile grid gap-2 p-4"
                    >
                      <FormLabel
                        class="flex items-center gap-2 text-sm font-medium"
                      >
                        <ShieldCheck class="h-4 w-4 text-primary" />
                        {{ t('auth.forgotPassword.captcha') }}
                      </FormLabel>
                      <div
                        class="grid w-full min-w-0 gap-2 sm:flex sm:items-center"
                      >
                        <FormControl>
                          <PinInput
                            id="captcha"
                            v-model="value"
                            class="justify-center sm:flex-1 sm:justify-start"
                            placeholder="○"
                          >
                            <PinInputGroup>
                              <PinInputSlot
                                v-for="(id, index) in 6"
                                :key="id"
                                :index="index"
                              />
                            </PinInputGroup>
                          </PinInput>
                        </FormControl>
                        <AppButton
                          type="button"
                          variant="secondary"
                          @click="sendCaptcha"
                          :disabled="isCaptchaSending || isLoading"
                          :loading="isCaptchaSending"
                          class="h-11 w-full rounded-full bg-card hover:bg-accent sm:w-auto"
                        >
                          <span v-if="isCaptchaSending">
                            {{ countdown }}
                            {{
                              t(
                                'auth.forgotPassword.captchaSentSecondDescription'
                              )
                            }}
                          </span>
                          <span v-else>
                            {{ t('auth.forgotPassword.sendCaptcha') }}
                          </span>
                        </AppButton>
                      </div>
                      <FormMessage />
                    </div>
                  </FormItem>
                </FormField>

                <AppButton
                  type="submit"
                  class="h-11 w-full rounded-full font-semibold"
                  :loading="isLoading"
                  :loading-label="
                    t('auth.forgotPassword.resetPassword')
                  "
                >
                  {{ t('auth.forgotPassword.resetPassword') }}
                </AppButton>

                <div
                  class="after:border-border relative text-center text-xs after:absolute after:inset-0 after:top-1/2 after:z-0 after:flex after:items-center after:border-t"
                >
                  <span
                    class="bg-card text-muted-foreground relative z-10 px-2"
                  >
                    {{ t('auth.forgotPassword.haveAccount') }}
                  </span>
                </div>

                <NuxtLink
                  :to="localePath('auth-login')"
                  class="pressable inline-flex h-11 w-full items-center justify-center rounded-full bg-secondary px-4 py-2 text-sm font-medium text-foreground transition-colors hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none"
                >
                  {{ t('auth.forgotPassword.loginPrompt') }}
                </NuxtLink>
              </form>
            </CardContent>
          </Card>
        </div>
      </div>
    </div>

    <!-- Right: Decorative showcase column -->
    <div class="relative hidden overflow-hidden bg-secondary/70 bg-subtle-grid p-10 lg:flex lg:items-center lg:justify-center">
      <div
        class="bento-card flex size-40 items-center justify-center"
      >
        <div
          class="flex size-24 items-center justify-center rounded-[20px] bg-[var(--primary-soft)]"
        >
          <KeyRound class="size-12 text-primary" />
        </div>
      </div>
      <div class="absolute bottom-8 left-8 right-8 z-10">
        <div class="liquid-glass-popover rounded-[26px] p-6">
          <blockquote class="space-y-2">
            <p
              class="text-[17px] font-medium leading-[1.62] text-foreground/90"
            >
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
