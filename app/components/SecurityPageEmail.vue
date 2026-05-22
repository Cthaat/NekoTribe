<script setup lang="ts">
import { toTypedSchema } from '@vee-validate/zod';
import { useForm } from 'vee-validate';
import { ref } from 'vue';
import * as z from 'zod';
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
  v2ChangeEmail,
  v2CreateOtp,
  v2LogoutCurrent
} from '@/services';
import { usePreferenceStore } from '~/stores/user';

const preferenceStore = usePreferenceStore();
const { t } = useAppLocale();
const localePath = useLocalePath();

const value = ref<string[]>([]);
const verificationId = ref('');

const isCaptchaSending = ref(false);
const countdown = ref(60);
let timer: ReturnType<typeof setInterval> | null = null;
const isLoading = ref(false);

async function sendCaptcha(): Promise<void> {
  const email = preferenceStore.preferences.user.email;

  isCaptchaSending.value = true;
  countdown.value = 60;

  try {
    const response = await v2CreateOtp({
      account: email,
      type: 'change_email',
      channel: 'email'
    });
    verificationId.value = response.verificationId;

    toast.success(
      t('account.security.securityPage.email.captchaSent'),
      {
        description: t(
          'account.security.securityPage.email.captchaSentDescription'
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
        : t('account.security.securityPage.email.unknownError');
    toast.error(
      t('account.security.securityPage.email.captchaSendError'),
      { description: message }
    );
  }
}

const emailChangeFormSchema = z.object({
  email: z
    .string()
    .trim()
    .email(
      t('account.security.securityPage.email.emailInvalid')
    ),
  captcha: z.string()
});
type EmailChangeFormValues = z.infer<typeof emailChangeFormSchema>;

const { handleSubmit } = useForm<EmailChangeFormValues>({
  validationSchema: toTypedSchema(emailChangeFormSchema),
  initialValues: {
    email: '',
    captcha: ''
  }
});

const onSubmit = handleSubmit(
  async (values: EmailChangeFormValues): Promise<void> => {
    isLoading.value = true;
    try {
      if (!verificationId.value) {
        throw new Error(
          t(
            'account.security.securityPage.email.captchaSendError'
          )
        );
      }
      await v2ChangeEmail({
        newEmail: values.email,
        verificationId: verificationId.value,
        code: value.value.join('')
      });
      toast.success(
        t(
          'account.security.securityPage.email.emailChangeSuccess'
        ),
        {
          description: t(
            'account.security.securityPage.email.emailChangeSuccessDescription'
          )
        }
      );
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : t(
              'account.security.securityPage.email.unknownError'
            );
      toast.error(
        t(
          'account.security.securityPage.email.emailChangeError'
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
          t('account.security.securityPage.email.logoutError')
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
    <FormField v-slot="{ componentField }" name="email">
      <FormItem class="grid gap-2">
        <FormLabel class="text-xs font-medium">
          {{
            t(
              'account.security.securityPage.email.emailLabel'
            )
          }}
        </FormLabel>
        <FormControl>
          <Input
            type="email"
            autocomplete="email"
            :placeholder="
              t(
                'account.security.securityPage.email.emailPlaceholder'
              )
            "
            v-bind="componentField"
            class="h-9 shadow-xs"
          />
        </FormControl>
        <FormDescription class="text-[11px] text-muted-foreground">
          {{
            t(
              'account.security.securityPage.email.emailDescription'
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
            t(
              'account.security.securityPage.email.captchaLabel'
            )
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
                  'account.security.securityPage.email.secondsLeft'
                )
              }}
            </span>
            <span v-else>
              {{
                t(
                  'account.security.securityPage.email.sendCaptcha'
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
            'account.security.securityPage.email.updateButton'
          )
        "
        class="h-9 w-full rounded-md shadow-xs sm:w-fit"
      >
        {{
          t('account.security.securityPage.email.updateButton')
        }}
      </AppButton>
    </div>
  </form>
</template>
