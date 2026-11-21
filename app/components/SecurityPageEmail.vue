<script setup lang="ts">
import { toTypedSchema } from '@vee-validate/zod';
import { useForm } from 'vee-validate';
import { ref, watch, onUnmounted } from 'vue';
import { otpRetryDelay } from '~/utils/otpRetryAfter';
import * as z from 'zod/v3';
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
} from '@/services';
import { usePreferenceStore } from '~/stores/user';

const preferenceStore = usePreferenceStore();
const props = defineProps<{onSessionCleared?: (result: {revision: number; ok: boolean}) => void}>();
const ownerRevision = preferenceStore.authRevision();
const { t } = useAppLocale();
const localePath = useLocalePath();

const value = ref<string[]>([]);
const verificationId = ref('');
const verificationAccount = ref('');
const verificationAuthRevision = ref<number | null>(null);
let otpRequestVersion = 0;
let otpDisposed = false;

const isCaptchaSending = ref(false);
const countdown = ref(60);
let timer: ReturnType<typeof setInterval> | null = null;
const isLoading = ref(false);

function resetVerification(): void {
  otpRequestVersion++;
  verificationId.value = '';
  verificationAccount.value = '';
  verificationAuthRevision.value = null;
  value.value = [];
  isCaptchaSending.value = false;
  if (timer) clearInterval(timer);
  timer = null;
}

function isOtpCurrent(version: number, account: string, authRevision: number): boolean {
  return !otpDisposed && preferenceStore.isAuthCurrent(ownerRevision) && version === otpRequestVersion &&
    form.values.email?.trim() === account && preferenceStore.isAuthCurrent(authRevision);
}

function beginOtpCooldown(seconds: number, version: number, account: string, authRevision: number): void {
  const endsAt = Date.now() + seconds * 1000;
  countdown.value = seconds;
  timer = setInterval(() => {
    if (!isOtpCurrent(version, account, authRevision)) {
      if (version === otpRequestVersion) resetVerification();
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
  if (isCaptchaSending.value || isLoading.value || otpDisposed || !preferenceStore.isAuthCurrent(ownerRevision)) return;
  const account = form.values.email?.trim();
  if (!account) return;
  if (!z.string().email().safeParse(account).success) {
    toast.error(t('account.security.securityPage.email.emailInvalid'));
    return;
  }
  const previous = { id: verificationId.value, account: verificationAccount.value, code: [...value.value], revision: verificationAuthRevision.value };
  resetVerification();
  const version = otpRequestVersion, authRevision = preferenceStore.authRevision();
  isCaptchaSending.value = true;
  countdown.value = 60;

  try {
    const response = await v2CreateOtp({
      account,
      type: 'change_email',
      channel: 'email'
    });
    if (!isOtpCurrent(version, account, authRevision)) return;
    if (response.account !== account || !response.verificationId?.trim()) {
      throw new Error(t('account.security.securityPage.email.captchaSendError'));
    }
    verificationId.value = response.verificationId;
    verificationAccount.value = account;
    verificationAuthRevision.value = authRevision;

    toast.success(
      t('account.security.securityPage.email.captchaSent'),
      {
        description: t(
          'account.security.securityPage.email.captchaSentDescription'
        )
      }
    );

    beginOtpCooldown(60, version, account, authRevision);
  } catch (error) {
    if (!isOtpCurrent(version, account, authRevision)) return;
    const retry = otpRetryDelay(error);
    if (retry !== null) {
      if (previous.id && previous.account === account && previous.revision === authRevision) {
        verificationId.value = previous.id;
        verificationAccount.value = previous.account;
        value.value = previous.code;
        verificationAuthRevision.value = authRevision;
      }
      beginOtpCooldown(retry, version, account, authRevision);
    }
    const message =
      error instanceof Error
        ? error.message
        : t('account.security.securityPage.email.unknownError');
    toast.error(
      t('account.security.securityPage.email.captchaSendError'),
      { description: message }
    );
  } finally {
    if (version === otpRequestVersion && !timer) isCaptchaSending.value = false;
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

const form = useForm<EmailChangeFormValues>({
  validationSchema: toTypedSchema(emailChangeFormSchema),
  initialValues: {
    email: '',
    captcha: ''
  }
});
const { handleSubmit } = form;
watch(() => form.values.email?.trim(), resetVerification, { flush: 'sync' });
watch(() => preferenceStore.preferences.user.email, resetVerification, { flush: 'sync' });
onUnmounted(() => { otpDisposed = true; resetVerification(); form.resetForm({values: {email: '', captcha: ''}}); });

const onSubmit = handleSubmit(
  async (values: EmailChangeFormValues): Promise<void> => {
    if (isLoading.value || otpDisposed || !preferenceStore.isAuthCurrent(ownerRevision)) return;
    const authRevision = preferenceStore.authRevision();
    const otpVersion = otpRequestVersion, account = values.email.trim();
    isLoading.value = true;
    let mutationSucceeded = false;
    try {
      if (!isOtpCurrent(otpVersion, account, authRevision) || !verificationId.value ||
          verificationAccount.value !== account || verificationAuthRevision.value !== authRevision) {
        throw new Error(
          t(
            'account.security.securityPage.email.captchaSendError'
          )
        );
      }
      await v2ChangeEmail({
        newEmail: account,
        verificationId: verificationId.value,
        code: value.value.join('')
      });
      mutationSucceeded = true;
      if (!isOtpCurrent(otpVersion, account, authRevision)) return;
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
      if (!isOtpCurrent(otpVersion, account, authRevision)) return;
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
        if (!mutationSucceeded || !isOtpCurrent(otpVersion, account, authRevision)) return;
        const finish = props.onSessionCleared;
        const result = await preferenceStore.logoutCurrentSession(authRevision);
        if (finish && result) { finish(result); return; }
        if (otpDisposed || !result || !preferenceStore.isAuthCurrent(result.revision)) return;
        if (!result.ok) throw result.error;
        setTimeout(() => {
          if (!otpDisposed && preferenceStore.isAuthCurrent(result.revision)) {
            navigateTo(localePath('auth-login'));
          }
        }, 2000);
      } catch {
        if (otpDisposed) return;
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
