<script setup lang="ts">
definePageMeta({
  layout: false
});

import { ref, watch, onUnmounted } from 'vue';
import { Button } from '@/components/ui/button';
import AppButton from '@/components/app/AppButton.vue';
import { Input } from '@/components/ui/input';
import { Checkbox } from '@/components/ui/checkbox';
import { Textarea } from '@/components/ui/textarea';
import {
  DateFormatter,
  type DateValue,
  getLocalTimeZone
} from '@internationalized/date';
import {
  CalendarIcon,
  Cat,
  Eye,
  EyeOff,
  Mail,
  User,
  Lock,
  ShieldCheck
} from 'lucide-vue-next';
import BirthdayCalendar from '@/components/BirthdayCalendar.vue';
import {
  Popover,
  PopoverContent,
  PopoverTrigger
} from '@/components/ui/popover';
import { cn } from '@/lib/utils';
import * as z from 'zod';
import { toTypedSchema } from '@vee-validate/zod';
import { useForm } from 'vee-validate';
import { toast } from 'vue-sonner';
import {
  v2CreateOtp,
  v2Register,
  v2VerifyOtp
} from '@/services';
import {
  PinInput,
  PinInputGroup,
  PinInputSlot
} from '@/components/ui/pin-input';
import {
  FormControl,
  FormField,
  FormItem,
  FormLabel,
  FormMessage
} from '@/components/ui/form';

import { navigateTo } from '#app';

const { t, locale } = useAppLocale();
const localePath = useLocalePath();

const description = t('auth.signUp.description');
useHead({
  title: t('auth.signUp.title'),
  meta: [
    {
      name: 'description',
      content: description
    }
  ]
});

const signUpFormSchema = z
  .object({
    email: z
      .string()
      .trim()
      .email({ message: t('auth.signUp.emailInvalid') }),
    username: z
      .string()
      .trim()
      .min(2, {
        message: t('auth.signUp.usernameRequired')
      }),
    displayName: z
      .string()
      .trim()
      .min(2, {
        message: t('auth.signUp.displayNameRequired')
      }),
    phone: z.string(),
    birthDate: z.custom<DateValue>().optional(),
    location: z.string(),
    bio: z.string(),
    password: z.string().min(6, {
      message: t('auth.signUp.passwordTooShort')
    }),
    confirmPassword: z.string().min(6, {
      message: t('auth.signUp.passwordTooShort')
    }),
    captcha: z.string(),
    agreeToTerms: z.boolean().refine(val => val === true, {
      message: t('auth.signUp.termsNotAgreed')
    })
  })
  .refine(
    data => data.password === data.confirmPassword,
    {
      message: t('auth.signUp.passwordMismatch'),
      path: ['confirmPassword']
    }
  );
type SignUpFormValues = z.infer<typeof signUpFormSchema>;

const form = useForm<SignUpFormValues>({
  validationSchema: toTypedSchema(signUpFormSchema),
  initialValues: {
    email: '',
    username: '',
    displayName: '',
    phone: '',
    birthDate: undefined,
    location: '',
    bio: '',
    password: '',
    confirmPassword: '',
    captcha: '',
    agreeToTerms: false
  }
});

const isLoading = ref(false);
const showPassword = ref(false);
const showConfirmPassword = ref(false);

const value = ref<string[]>([]);
const verificationId = ref('');

const isCaptchaSending = ref(false);
const countdown = ref(60);
let timer: ReturnType<typeof setInterval> | null = null;

async function sendCaptcha(): Promise<void> {
  const { valid, errors } =
    await form.validateField('email');
  if (!valid) {
    toast.error(t('auth.signUp.captchaSendError'), {
      description:
        errors[0] || t('auth.signUp.emailInvalid')
    });
    return;
  }
  const email = form.values.email;

  isCaptchaSending.value = true;
  countdown.value = 60;

  try {
    const response = await v2CreateOtp({
      account: email,
      type: 'register',
      channel: 'email'
    });
    verificationId.value = response.verificationId;

    toast.success(t('auth.signUp.captchaSent'), {
      description: t('auth.signUp.captchaSentDescription')
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
        : t('auth.signUp.unknownError');
    toast.error(t('auth.signUp.captchaSendError'), {
      description: message
    });
  }
}

onUnmounted(() => {
  if (timer) {
    clearInterval(timer);
  }
});

async function onValidSubmit(
  values: SignUpFormValues
): Promise<void> {
  isLoading.value = true;

  try {
    if (!verificationId.value) {
      throw new Error(t('auth.signUp.captchaSendError'));
    }

    await v2VerifyOtp({
      account: values.email,
      type: 'register',
      verificationId: verificationId.value,
      code: value.value.join('')
    });

    await v2Register({
      email: values.email,
      username: values.username,
      password: values.password,
      confirmPassword: values.confirmPassword,
      displayName: values.displayName,
      phone: values.phone.trim() || undefined,
      birthDate: values.birthDate
        ? values.birthDate.toString()
        : undefined,
      location: values.location.trim() || undefined,
      bio: values.bio.trim() || undefined,
      verificationId: verificationId.value,
      agreeToTerms: values.agreeToTerms
    });

    toast(t('auth.signUp.successRegister'), {
      description: t('auth.signUp.redirectToLogin')
    });
    await navigateTo(localePath('/auth/login'));
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : t('auth.signUp.unknownError');
    toast.error(t('auth.signUp.registerFailed'), {
      description: message
    });
  } finally {
    isLoading.value = false;
  }
}

const df = new DateFormatter(
  locale.value === 'zh' ? 'zh-CN' : 'en-US',
  {
    dateStyle: 'long'
  }
);

const onSubmit = form.handleSubmit(onValidSubmit);

const agreeToTermsValue = ref(false);

watch(agreeToTermsValue, newValue => {
  form.setFieldValue('agreeToTerms', newValue);
});
</script>

<template>
  <div class="relative min-h-svh w-full bg-background">
    <!-- Top bar with brand -->
    <header
      class="sticky top-0 z-20 border-b bg-background/80 backdrop-blur"
    >
      <div
        class="mx-auto flex max-w-6xl items-center justify-between px-6 py-3"
      >
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
        <NuxtLink
          :to="localePath('/auth/login')"
          class="text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
        >
          {{ t('auth.signUp.loginPrompt') }}
        </NuxtLink>
      </div>
    </header>

    <div class="mx-auto w-full max-w-2xl px-4 py-10 md:py-16">
      <div class="mb-8 space-y-2 text-center">
        <h1 class="text-3xl font-semibold tracking-tight">
          {{ t('auth.signUp.signUpPrompt') }}
        </h1>
        <p class="text-balance text-sm text-muted-foreground">
          {{ t('auth.signUp.signUpPromptDescription') }}
        </p>
      </div>

      <div
        class="overflow-hidden rounded-xl border border-border/60 bg-card shadow-none"
      >
        <div class="p-6 md:p-8">
          <form class="grid gap-6" @submit="onSubmit">
            <!-- Section: Account -->
            <section class="grid gap-4">
              <div class="flex items-start gap-3">
                <span
                  class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
                >
                  <Mail class="h-4 w-4" />
                </span>
                <div class="min-w-0 grid gap-0.5">
                  <h3 class="text-sm font-semibold tracking-tight">
                    {{ t('auth.signUp.email') }}
                  </h3>
                  <p class="text-[11px] text-muted-foreground">
                    {{ t('auth.signUp.emailPlaceholder') }}
                  </p>
                </div>
              </div>

              <FormField
                v-slot="{ componentField }"
                name="email"
              >
                <FormItem>
                  <FormLabel class="sr-only">
                    {{ t('auth.signUp.email') }}
                  </FormLabel>
                  <FormControl>
                    <Input
                      id="email"
                      type="email"
                      autocomplete="email"
                      :disabled="isLoading"
                      :placeholder="t('auth.signUp.emailPlaceholder')"
                      v-bind="componentField"
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              </FormField>
            </section>

            <div class="h-px w-full bg-border/60" />

            <!-- Section: Identity -->
            <section class="grid gap-4">
              <div class="flex items-start gap-3">
                <span
                  class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-violet-500/10 text-violet-600 dark:text-violet-400"
                >
                  <User class="h-4 w-4" />
                </span>
                <div class="min-w-0 grid gap-0.5">
                  <h3 class="text-sm font-semibold tracking-tight">
                    {{ t('auth.signUp.username') }} / {{ t('auth.signUp.displayName') }}
                  </h3>
                  <p class="text-[11px] text-muted-foreground">
                    {{ t('auth.signUp.usernamePlaceholder') }}
                  </p>
                </div>
              </div>

              <div class="grid gap-4 md:grid-cols-2">
                <FormField
                  v-slot="{ componentField }"
                  name="username"
                >
                  <FormItem>
                    <FormLabel>{{
                      t('auth.signUp.username')
                    }}</FormLabel>
                    <FormControl>
                      <Input
                        id="username"
                        type="text"
                        :disabled="isLoading"
                        :placeholder="
                          t('auth.signUp.usernamePlaceholder')
                        "
                        v-bind="componentField"
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                </FormField>

                <FormField
                  v-slot="{ componentField }"
                  name="displayName"
                >
                  <FormItem>
                    <FormLabel>{{
                      t('auth.signUp.displayName')
                    }}</FormLabel>
                    <FormControl>
                      <Input
                        id="displayName"
                        type="text"
                        :disabled="isLoading"
                        :placeholder="
                          t('auth.signUp.displayNamePlaceholder')
                        "
                        v-bind="componentField"
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                </FormField>

                <FormField
                  v-slot="{ componentField }"
                  name="phone"
                >
                  <FormItem>
                    <FormLabel>{{
                      t('auth.signUp.phone')
                    }}</FormLabel>
                    <FormControl>
                      <Input
                        id="phone"
                        type="tel"
                        autocomplete="tel"
                        :disabled="isLoading"
                        :placeholder="
                          t('auth.signUp.phonePlaceholder')
                        "
                        v-bind="componentField"
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                </FormField>

                <FormField
                  v-slot="{ componentField, value }"
                  name="birthDate"
                >
                  <FormItem class="flex flex-col">
                    <FormLabel>{{
                      t('auth.signUp.birthDate')
                    }}</FormLabel>
                    <Popover>
                      <PopoverTrigger as-child>
                        <FormControl>
                          <Button
                            variant="outline"
                            :class="
                              cn(
                                'h-9 w-full justify-start text-left font-normal',
                                !value &&
                                  'text-muted-foreground'
                              )
                            "
                          >
                            <CalendarIcon
                              class="mr-2 h-4 w-4"
                            />
                            {{
                              value
                                ? df.format(
                                    value.toDate(
                                      getLocalTimeZone()
                                    )
                                  )
                                : t(
                                    'auth.signUp.birthDatePlaceholder'
                                  )
                            }}
                          </Button>
                        </FormControl>
                      </PopoverTrigger>
                      <PopoverContent class="w-auto p-0">
                        <BirthdayCalendar
                          v-bind="componentField"
                        />
                      </PopoverContent>
                    </Popover>
                    <FormMessage />
                  </FormItem>
                </FormField>
              </div>

              <FormField
                v-slot="{ componentField }"
                name="location"
              >
                <FormItem>
                  <FormLabel>{{
                    t('auth.signUp.location')
                  }}</FormLabel>
                  <FormControl>
                    <Input
                      id="location"
                      type="text"
                      :disabled="isLoading"
                      :placeholder="
                        t('auth.signUp.locationPlaceholder')
                      "
                      v-bind="componentField"
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              </FormField>

              <FormField v-slot="{ componentField }" name="bio">
                <FormItem>
                  <FormLabel>{{
                    t('auth.signUp.bio')
                  }}</FormLabel>
                  <FormControl>
                    <Textarea
                      id="bio"
                      :disabled="isLoading"
                      :placeholder="
                        t('auth.signUp.bioPlaceholder')
                      "
                      class="min-h-20 resize-none"
                      v-bind="componentField"
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              </FormField>
            </section>

            <div class="h-px w-full bg-border/60" />

            <!-- Section: Security -->
            <section class="grid gap-4">
              <div class="flex items-start gap-3">
                <span
                  class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
                >
                  <Lock class="h-4 w-4" />
                </span>
                <div class="min-w-0 grid gap-0.5">
                  <h3 class="text-sm font-semibold tracking-tight">
                    {{ t('auth.signUp.password') }}
                  </h3>
                  <p class="text-[11px] text-muted-foreground">
                    {{ t('auth.signUp.passwordPlaceholder') }}
                  </p>
                </div>
              </div>

              <div class="grid gap-4 md:grid-cols-2">
                <FormField
                  v-slot="{ componentField }"
                  name="password"
                >
                  <FormItem>
                    <FormLabel>{{
                      t('auth.signUp.password')
                    }}</FormLabel>
                    <FormControl>
                      <div class="relative">
                        <Input
                          id="password"
                          :type="showPassword ? 'text' : 'password'"
                          autocomplete="new-password"
                          :disabled="isLoading"
                          :placeholder="
                            t('auth.signUp.passwordPlaceholder')
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

                <FormField
                  v-slot="{ componentField }"
                  name="confirmPassword"
                >
                  <FormItem>
                    <FormLabel>{{
                      t('auth.signUp.confirmPassword')
                    }}</FormLabel>
                    <FormControl>
                      <div class="relative">
                        <Input
                          id="confirmPassword"
                          :type="showConfirmPassword ? 'text' : 'password'"
                          autocomplete="new-password"
                          :disabled="isLoading"
                          :placeholder="
                            t(
                              'auth.signUp.confirmPasswordPlaceholder'
                            )
                          "
                          class="pr-10"
                          v-bind="componentField"
                        />
                        <button
                          type="button"
                          tabindex="-1"
                          class="absolute right-2 top-1/2 -translate-y-1/2 rounded-md p-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                          @click="showConfirmPassword = !showConfirmPassword"
                        >
                          <component
                            :is="showConfirmPassword ? EyeOff : Eye"
                            class="h-4 w-4"
                          />
                        </button>
                      </div>
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                </FormField>
              </div>
            </section>

            <div class="h-px w-full bg-border/60" />

            <!-- Section: Verification -->
            <section class="grid gap-4">
              <div class="flex items-start gap-3">
                <span
                  class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-amber-500/10 text-amber-600 dark:text-amber-400"
                >
                  <ShieldCheck class="h-4 w-4" />
                </span>
                <div class="min-w-0 grid gap-0.5">
                  <h3 class="text-sm font-semibold tracking-tight">
                    {{ t('auth.signUp.captcha') }}
                  </h3>
                  <p class="text-[11px] text-muted-foreground">
                    {{ t('auth.signUp.captchaSentDescription') }}
                  </p>
                </div>
              </div>

              <FormField
                v-slot="{ componentField }"
                name="captcha"
              >
                <FormItem>
                  <FormLabel class="sr-only">{{
                    t('auth.signUp.captcha')
                  }}</FormLabel>
                  <div
                    class="grid w-full gap-3 sm:flex sm:items-center"
                  >
                    <FormControl>
                      <PinInput
                        class="justify-center sm:flex-1 sm:justify-start"
                        id="captcha"
                        v-model="value"
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
                        {{
                          t('auth.signUp.captchaSecondsLeft', {
                            count: countdown
                          })
                        }}
                      </span>
                      <span v-else>
                        {{ t('auth.signUp.sendCaptcha') }}
                      </span>
                    </AppButton>
                  </div>
                  <FormMessage />
                </FormItem>
              </FormField>
            </section>

            <div class="h-px w-full bg-border/60" />

            <!-- Terms -->
            <FormField name="agreeToTerms">
              <FormItem
                class="flex flex-row items-start gap-3 rounded-lg border border-border/60 bg-muted/20 p-4"
              >
                <FormControl>
                  <Checkbox
                    v-model="agreeToTermsValue"
                    class="mt-0.5"
                  />
                </FormControl>
                <div class="grid gap-1.5 leading-none">
                  <FormLabel
                    class="cursor-pointer text-sm font-medium leading-relaxed peer-disabled:cursor-not-allowed peer-disabled:opacity-70"
                  >
                    {{ t('auth.signUp.agreeToTerms') }}
                    <NuxtLink
                      :to="localePath('/auth/terms')"
                      class="text-primary underline-offset-4 hover:underline"
                    >
                      {{ t('auth.signUp.termsLink') }}
                    </NuxtLink>
                  </FormLabel>
                  <FormMessage />
                </div>
              </FormItem>
            </FormField>

            <AppButton
              type="submit"
              class="w-full"
              :loading="isLoading"
              :loading-label="t('auth.signUp.signUpButton')"
            >
              {{ t('auth.signUp.signUpButton') }}
            </AppButton>
          </form>
        </div>
      </div>

      <p class="mt-6 text-center text-sm text-muted-foreground">
        {{ t('auth.signUp.haveAccount') }}
        <NuxtLink
          :to="localePath('/auth/login')"
          class="font-medium text-foreground underline-offset-4 hover:underline"
        >
          {{ t('auth.signUp.loginPrompt') }}
        </NuxtLink>
      </p>
    </div>
  </div>
</template>
