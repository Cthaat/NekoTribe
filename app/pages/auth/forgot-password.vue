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
import AppCard from '@/components/app/AppCard.vue';
import { Input } from '@/components/ui/input';
import { toast } from 'vue-sonner';

const verifiedEmails = ref([
  'm@example.com',
  'm@google.com',
  'm@support.com'
]);
import {
  v2CreateOtp,
  v2LogoutCurrent,
  v2PasswordReset
} from '@/services';
import { usePreferenceStore } from '~/stores/user'; // 导入 store

// 无页面布局
definePageMeta({
  layout: false
});

const preferenceStore = usePreferenceStore();

const { t } = useAppLocale();

const localePath = useLocalePath();

const value = ref<string[]>([]);
const verificationId = ref('');

const isConfirmPasswordVisible = ref(false);
const isPasswordVisible = ref(false);
const isLoading = ref(false);

// --- 新增：为验证码按钮添加状态 ---
const isCaptchaSending = ref(false);
const countdown = ref(60);
let timer: ReturnType<typeof setInterval> | null = null; // 用于存储定时器实例
const email = ref('');

async function sendCaptcha(): Promise<void> {
  // 1. 进入发送状态，禁用按钮
  isCaptchaSending.value = true;
  countdown.value = 60; // 重置倒计时

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

    // 发送成功后，禁用按钮60秒，并且显示还剩多少时间

    // 4. API 调用成功后，启动定时器
    timer = setInterval(() => {
      if (countdown.value > 0) {
        countdown.value--;
      } else {
        // 倒计时结束
        isCaptchaSending.value = false;
        if (timer) {
          clearInterval(timer);
          timer = null;
        }
      }
    }, 1000); // 每秒执行一次
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : t('auth.forgotPassword.unknownError');
    console.error(
      t('auth.forgotPassword.captchaSendError'),
      error
    );
    isCaptchaSending.value = false; // 发送失败时也要重置状态
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
      .email(t('auth.forgotPassword.emailInvalid'))
      .refine(
        currentEmail =>
          !verifiedEmails.value.includes(currentEmail),
        {
          message: t(
            'auth.forgotPassword.emailAlreadyVerified'
          )
        }
      ),
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

const { handleSubmit } =
  useForm<ForgotPasswordFormValues>({
    validationSchema: toTypedSchema(
      forgotPasswordFormSchema
    ),
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
      throw new Error(t('auth.forgotPassword.captchaSendError'));
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
    console.error(
      t('auth.forgotPassword.resetPasswordError'),
      error
    );
    toast.error(
      t('auth.forgotPassword.resetPasswordError'),
      {
        description: message
      }
    );
  } finally {
    try {
      preferenceStore.resetToDefaults(); // 重置用户偏好设置
      await v2LogoutCurrent();
      // 等待两秒
      setTimeout(() => {
        navigateTo(localePath('auth-login'));
      }, 2000);
    } catch (error) {
      toast.error(t('account.security.securityPage.password.logoutError'));
    } finally {
      isLoading.value = false;
    }
  }
  }
);
</script>

<template>
  <div
    class="min-h-screen w-full bg-background lg:grid lg:grid-cols-2"
  >
    <div class="flex items-center justify-center px-4 py-12">
      <AppCard class="w-full max-w-sm shadow-sm" content-class="grid gap-6">
        <template #header>
          <div class="grid gap-2 text-center">
            <h1 class="text-3xl font-semibold tracking-tight">
              {{ t('auth.forgotPassword.title') }}
            </h1>
            <p class="text-sm text-muted-foreground">
              {{
                t('auth.forgotPassword.forgotPasswordPrompt')
              }}
            </p>
          </div>
        </template>

        <form class="space-y-8" @submit="onSubmit">
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
                  :placeholder="
                    t(
                      'auth.forgotPassword.emailPlaceholder'
                    )
                  "
                  v-bind="componentField"
                  v-model="email"
                  :disabled="isLoading"
                  class="pr-10"
                />
              </FormControl>
              <FormDescription>
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
              <div class="relative">
                <FormControl>
                  <Input
                    :type="
                      isPasswordVisible
                        ? 'text'
                        : 'password'
                    "
                    :placeholder="
                      t(
                        'auth.forgotPassword.newPasswordPlaceholder'
                      )
                    "
                    v-bind="componentField"
                    :disabled="isLoading"
                    class="pr-10"
                  />
                </FormControl>
                <AppButton
                  type="button"
                  variant="ghost"
                  size="icon"
                  @click="
                    isPasswordVisible = !isPasswordVisible
                  "
                  class="absolute inset-y-0 right-0 h-full rounded-l-none text-muted-foreground"
                >
                  <Eye
                    v-if="!isPasswordVisible"
                    class="size-4"
                  />
                  <EyeOff v-else class="size-4" />
                  <span class="sr-only"
                    >{{ t('common.togglePasswordVisibility') }}</span
                  >
                </AppButton>
              </div>
              <FormDescription>
                {{
                  t(
                    'auth.forgotPassword.newPasswordDescription'
                  )
                }}
              </FormDescription>
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
              <div class="relative">
                <FormControl>
                  <Input
                    :type="
                      isConfirmPasswordVisible
                        ? 'text'
                        : 'password'
                    "
                    :placeholder="
                      t(
                        'auth.forgotPassword.confirmPasswordPlaceholder'
                      )
                    "
                    v-bind="componentField"
                    :disabled="isLoading"
                    class="pr-10"
                  />
                </FormControl>
                <AppButton
                  type="button"
                  variant="ghost"
                  size="icon"
                  @click="
                    isConfirmPasswordVisible =
                      !isConfirmPasswordVisible
                  "
                  class="absolute inset-y-0 right-0 h-full rounded-l-none text-muted-foreground"
                >
                  <Eye
                    v-if="!isConfirmPasswordVisible"
                    class="size-4"
                  />
                  <EyeOff v-else class="size-4" />
                  <span class="sr-only"
                    >{{ t('common.togglePasswordVisibility') }}</span
                  >
                </AppButton>
              </div>
              <FormDescription>
                {{
                  t(
                    'auth.forgotPassword.confirmPasswordDescription'
                  )
                }}
              </FormDescription>
              <FormMessage />
            </FormItem>
          </FormField>

          <!-- 验证码和服务条款区域 (两列) -->
          <FormField
            v-slot="{ componentField }"
            name="captcha"
          >
            <FormItem>
              <FormLabel>{{
                t('auth.forgotPassword.captcha')
              }}</FormLabel>
              <!-- 
      使用一个 div 作为 Flexbox 容器，
      它将包裹输入框和按钮，让它们在同一行显示。
    -->
              <div
                class="flex w-full items-center gap-x-2 justify-start"
              >
                <FormControl>
                  <!-- 
          flex-1 是关键，它告诉输入框：
          "占据所有可用的剩余空间"。
        -->
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
                <!-- 
        按钮现在是 Flexbox 的一部分，它会自动收缩以适应其内容大小。
        type="button" 很重要，可以防止它意外触发表单提交。-->
                <AppButton
                  type="button"
                  @click="sendCaptcha"
                  :disabled="isCaptchaSending || isLoading"
                  :loading="isCaptchaSending"
                  class="w-32"
                >
                  <!-- 
    使用 v-if 和 v-else 来根据 isCaptchaSending 的状态显示不同的文本
  -->
                  <span v-if="isCaptchaSending">
                    {{ countdown }}
                    {{
                      t(
                        'auth.forgotPassword.captchaSentSecondDescription'
                      )
                    }}
                  </span>
                  <span v-else>
                    {{
                      t('auth.forgotPassword.sendCaptcha')
                    }}
                  </span>
                </AppButton>
              </div>
              <FormMessage />
            </FormItem>
          </FormField>

          <div class="flex gap-2 justify-start">
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
          </div>
        </form>
        <div class="mt-4 text-center text-sm">
          {{ t('auth.forgotPassword.haveAccount') }}
          <NuxtLink
            :to="localePath('auth-login')"
            class="underline"
          >
            {{ t('auth.forgotPassword.loginPrompt') }}
          </NuxtLink>
        </div>
      </AppCard>
    </div>
    <div class="hidden bg-muted lg:block">
      <img
        src="/placeholder.svg"
        :alt="t('auth.forgotPassword.coverImageAlt')"
        width="1920"
        height="1080"
        class="h-full w-full object-cover dark:brightness-[0.2] dark:grayscale"
      />
    </div>
  </div>
</template>


