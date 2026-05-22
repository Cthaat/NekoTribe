<script setup lang="ts">
import { toTypedSchema } from '@vee-validate/zod';
import { useForm } from 'vee-validate';
import { ref } from 'vue';
import * as z from 'zod';
import { Eye, EyeOff } from 'lucide-vue-next';
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
import { Input } from '@/components/ui/input';
import { toast } from 'vue-sonner';
import {
  v2CreateOtp,
  v2LogoutCurrent,
  v2PasswordReset
} from '@/services';
import { usePreferenceStore } from '~/stores/user';

const preferenceStore = usePreferenceStore();
const { t } = useAppLocale();
const localePath = useLocalePath();

const value = ref<string[]>([]);
const verificationId = ref('');

const isConfirmPasswordVisible = ref(false);
const isPasswordVisible = ref(false);
const isLoading = ref(false);

const isCaptchaSending = ref(false);
const countdown = ref(60);
let timer: ReturnType<typeof setInterval> | null = null;

async function sendCaptcha(): Promise<void> {
  const email = preferenceStore.preferences.user.email;

  isCaptchaSending.value = true;
  countdown.value = 60;

  try {
    const response = await v2CreateOtp({
      account: email,
      type: 'password_reset',
      channel: 'email'
    });
    verificationId.value = response.verificationId;

    toast.success(
      t('account.security.securityPage.password.captchaSent'),
      {
        description: t(
          'account.security.securityPage.password.captchaSentDescription'
        )
      }
    );

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
        : t('account.security.securityPage.password.unknownError');
    toast.error(
      t('account.security.securityPage.password.captchaSendError'),
      { description: message }
    );
  }
}

const passwordChangeFormSchema = z
  .object({
    newPassword: z.string().min(6, {
      message: t(
        'account.security.securityPage.password.passwordTooShort'
      )
    }),
    confirmPassword: z.string().min(6, {
      message: t(
        'account.security.securityPage.password.passwordTooShort'
      )
    }),
    captcha: z.string()
  })
  .refine(data => data.newPassword === data.confirmPassword, {
    message: t(
      'account.security.securityPage.password.passwordMismatch'
    ),
    path: ['confirmPassword']
  });
type PasswordChangeFormValues = z.infer<
  typeof passwordChangeFormSchema
>;

const { handleSubmit } = useForm<PasswordChangeFormValues>({
  validationSchema: toTypedSchema(passwordChangeFormSchema),
  initialValues: {
    newPassword: '',
    confirmPassword: '',
    captcha: ''
  }
});

const onSubmit = handleSubmit(
  async (values: PasswordChangeFormValues): Promise<void> => {
    isLoading.value = true;
    try {
      if (!verificationId.value) {
        throw new Error(
          t(
            'account.security.securityPage.password.captchaSendError'
          )
        );
      }
      await v2PasswordReset({
        email: preferenceStore.preferences.user.email,
        verificationId: verificationId.value,
        code: value.value.join(''),
        newPassword: values.newPassword
      });
      toast.success(
        t(
          'account.security.securityPage.password.resetPasswordSuccess'
        ),
        {
          description: t(
            'account.security.securityPage.password.resetPasswordSuccessDescription'
          )
        }
      );
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : t(
              'account.security.securityPage.password.unknownError'
            );
      toast.error(
        t(
          'account.security.securityPage.password.resetPasswordError'
        ),
        { description: message }
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
  <form class="grid gap-5" @submit="onSubmit">
    <FormField v-slot="{ componentField }" name="newPassword">
      <FormItem class="grid gap-2">
        <FormLabel class="text-xs font-medium">
          {{
            t(
              'account.security.securityPage.password.newPassword'
            )
          }}
        </FormLabel>
        <div class="relative">
          <FormControl>
            <Input
              :type="isPasswordVisible ? 'text' : 'password'"
              :placeholder="
                t(
                  'account.security.securityPage.password.newPassword'
                )
              "
              v-bind="componentField"
              class="h-9 pr-10 shadow-xs"
            />
          </FormControl>
          <button
            type="button"
            class="absolute inset-y-0 right-0 flex h-9 w-9 items-center justify-center rounded-md text-muted-foreground transition hover:text-foreground"
            @click="isPasswordVisible = !isPasswordVisible"
          >
            <Eye v-if="!isPasswordVisible" class="h-4 w-4" />
            <EyeOff v-else class="h-4 w-4" />
            <span class="sr-only">Toggle password visibility</span>
          </button>
        </div>
        <FormDescription class="text-[11px] text-muted-foreground">
          {{
            t(
              'account.security.securityPage.password.newPasswordDescription'
            )
          }}
        </FormDescription>
        <FormMessage class="text-[11px]" />
      </FormItem>
    </FormField>

    <FormField v-slot="{ componentField }" name="confirmPassword">
      <FormItem class="grid gap-2">
        <FormLabel class="text-xs font-medium">
          {{
            t(
              'account.security.securityPage.password.confirmPassword'
            )
          }}
        </FormLabel>
        <div class="relative">
          <FormControl>
            <Input
              :type="
                isConfirmPasswordVisible ? 'text' : 'password'
              "
              :placeholder="
                t(
                  'account.security.securityPage.password.confirmPassword'
                )
              "
              v-bind="componentField"
              class="h-9 pr-10 shadow-xs"
            />
          </FormControl>
          <button
            type="button"
            class="absolute inset-y-0 right-0 flex h-9 w-9 items-center justify-center rounded-md text-muted-foreground transition hover:text-foreground"
            @click="
              isConfirmPasswordVisible = !isConfirmPasswordVisible
            "
          >
            <Eye
              v-if="!isConfirmPasswordVisible"
              class="h-4 w-4"
            />
            <EyeOff v-else class="h-4 w-4" />
            <span class="sr-only">Toggle password visibility</span>
          </button>
        </div>
        <FormDescription class="text-[11px] text-muted-foreground">
          {{
            t(
              'account.security.securityPage.password.confirmPasswordDescription'
            )
          }}
        </FormDescription>
        <FormMessage class="text-[11px]" />
      </FormItem>
    </FormField>

    <FormField name="captcha">
      <FormItem class="grid gap-2">
        <FormLabel class="text-xs font-medium">
          {{
            t('account.security.securityPage.password.captcha')
          }}
        </FormLabel>
        <div
          class="flex w-full flex-col items-stretch gap-2 sm:flex-row sm:items-center"
        >
          <FormControl>
            <PinInput
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
            :disabled="isCaptchaSending || isLoading"
            :loading="isCaptchaSending"
            class="h-9 w-full rounded-md shadow-xs sm:w-32"
            @click="sendCaptcha"
          >
            <span v-if="isCaptchaSending">
              {{
                countdown +
                t(
                  'account.security.securityPage.password.captchaSecondsLeft'
                )
              }}
            </span>
            <span v-else>
              {{
                t(
                  'account.security.securityPage.password.sendCaptcha'
                )
              }}
            </span>
          </AppButton>
        </div>
        <FormMessage class="text-[11px]" />
      </FormItem>
    </FormField>

    <div class="flex justify-start gap-2 pt-1">
      <AppButton
        type="submit"
        :loading="isLoading"
        :loading-label="
          t(
            'account.security.securityPage.password.resetPassword'
          )
        "
        class="h-9 w-full rounded-md shadow-xs sm:w-fit"
      >
        {{
          t(
            'account.security.securityPage.password.resetPassword'
          )
        }}
      </AppButton>
    </div>
  </form>
</template>
