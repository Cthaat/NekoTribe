<script setup lang="ts">
definePageMeta({
  layout: false
});

import { toTypedSchema } from '@vee-validate/zod';
import { useForm } from 'vee-validate';
import { ref } from 'vue';
import * as z from 'zod';
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
  v2LogoutCurrent,
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

const isConfirmPasswordVisible = ref(false);
const isPasswordVisible = ref(false);
const isLoading = ref(false);

const isCaptchaSending = ref(false);
const countdown = ref(60);
let timer: ReturnType<typeof setInterval> | null = null;
const email = ref('');

async function sendCaptcha(): Promise<void> {
  isCaptchaSending.value = true;
  countdown.value = 60;

  try {
    const response = await v2CreateOtp({
      account: email.value,
      type: 'password_reset',
      channel: 'email'
    });
    verificationId.value = response.verificationId;

    toast.success(t('auth.forgotPassword.captchaSent'), {
      description: t(
        'auth.forgotPassword.captchaSentDescription'
      )
    });

    timer = setInterval(() => {
      if (countdown.value > 0) {
        countdown.value--;
      } else {
        isCaptchaSending.value = false;
        if (timer) {
          clearInterval(timer);
          timer = null;
        }
      }
    }, 1000);
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : t('auth.forgotPassword.unknownError');
    isCaptchaSending.value = false;
    toast.error(t('auth.forgotPassword.captchaSendError'), {
      description: message
    });
  }
}

const forgotPasswordFormSchema = z
  .object({
    email: z
      .string()
      .trim()
      .email(t('auth.forgotPassword.emailInvalid')),
    newPassword: z.string().min(6, {
      message: t('auth.forgotPassword.passwordTooShort')
    }),
    confirmPassword: z.string().min(6, {
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
    isLoading.value = true;
    try {
      if (!verificationId.value) {
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
      toast.success(
        t('auth.forgotPassword.resetPasswordSuccess'),
        {
          description: t(
            'auth.forgotPassword.resetPasswordSuccessDescription'
          )
        }
      );
    } catch (error) {
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
        preferenceStore.resetToDefaults();
        await v2LogoutCurrent();
        setTimeout(() => {
          navigateTo(localePath('auth-login'));
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
  <div class="relative grid min-h-svh w-full overflow-x-clip lg:grid-cols-2">
    <!-- Left: Form column -->
    <div class="flex min-w-0 flex-col gap-4 p-4 sm:p-6 md:p-10">
      <div class="flex justify-center gap-2 sm:justify-start">
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

      <div class="flex min-w-0 flex-1 items-center justify-center">
        <div class="w-full max-w-sm">
          <Card class="border-none shadow-none">
            <CardHeader class="space-y-1 px-0 text-center">
              <div
                class="mx-auto mb-2 flex h-12 w-12 items-center justify-center rounded-full bg-primary/10 ring-1 ring-primary/20"
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
                          class="pr-10"
                          v-bind="componentField"
                        />
                        <button
                          type="button"
                          tabindex="-1"
                          class="absolute right-2 top-1/2 -translate-y-1/2 rounded-md p-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
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
                          class="pr-10"
                          v-bind="componentField"
                        />
                        <button
                          type="button"
                          tabindex="-1"
                          class="absolute right-2 top-1/2 -translate-y-1/2 rounded-md p-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
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
                      class="grid gap-2 rounded-lg border border-border/60 bg-muted/30 p-4"
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
                          variant="outline"
                          @click="sendCaptcha"
                          :disabled="isCaptchaSending || isLoading"
                          :loading="isCaptchaSending"
                          class="w-full sm:w-auto"
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
                  class="w-full"
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
                    class="bg-background text-muted-foreground relative z-10 px-2"
                  >
                    {{ t('auth.forgotPassword.haveAccount') }}
                  </span>
                </div>

                <NuxtLink
                  :to="localePath('auth-login')"
                  class="inline-flex h-9 w-full items-center justify-center rounded-md border border-input bg-background px-4 py-2 text-sm font-medium shadow-xs transition-colors hover:bg-accent hover:text-accent-foreground"
                >
                  {{ t('auth.forgotPassword.loginPrompt') }}
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
        :alt="t('auth.forgotPassword.coverImageAlt')"
        width="1920"
        height="1080"
        class="absolute inset-0 h-full w-full object-cover dark:brightness-[0.2] dark:grayscale"
      />
      <div
        class="pointer-events-none absolute inset-0 bg-gradient-to-tr from-background/60 via-transparent to-background/30"
      />
      <div class="absolute bottom-8 left-8 right-8 z-10">
        <blockquote class="space-y-2">
          <p
            class="text-lg font-medium leading-relaxed text-foreground/90"
          >
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
