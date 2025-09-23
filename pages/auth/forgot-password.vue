<script setup lang="ts">
import { toTypedSchema } from '@vee-validate/zod';
import { FieldArray, useForm } from 'vee-validate';
import { h, ref } from 'vue';
import * as z from 'zod';
import { cn } from '@/lib/utils';
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
import {
  DateFormatter,
  type DateValue,
  getLocalTimeZone,
  parseDate
} from '@internationalized/date';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import { Separator } from '@/components/ui/separator';
import { Textarea } from '@/components/ui/textarea';
import { toast } from 'vue-sonner';

const verifiedEmails = ref([
  'm@example.com',
  'm@google.com',
  'm@support.com'
]);
import { apiFetch } from '@/composables/useApi';
import { usePreferenceStore } from '~/stores/user'; // 导入 store

// 无页面布局
definePageMeta({
  layout: false
});

const preferenceStore = usePreferenceStore();

const { t } = useI18n();

const localePath = useLocalePath();

const value = ref<string[]>([]);

const isConfirmPasswordVisible = ref(false);
const isPasswordVisible = ref(false);

// --- 新增：为验证码按钮添加状态 ---
const isCaptchaSending = ref(false);
const countdown = ref(60);
let timer: ReturnType<typeof setInterval> | null = null; // 用于存储定时器实例
const email = ref('');

async function sendCaptcha() {
  // 1. 进入发送状态，禁用按钮
  isCaptchaSending.value = true;
  countdown.value = 60; // 重置倒计时

  try {
    // 1. 调用 API，等待它完成
    const response: any = await apiFetch(
      '/api/v1/auth/get-verification',
      {
        method: 'POST',
        body: {
          account: email.value
        }
      }
    );
    console.log(response);

    toast.success('the auth.forgotPassword.captchaSent', {
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
  } catch (error: any) {
    // 错误处理逻辑保持不变
    console.error(
      t('auth.forgotPassword.captchaSendError'),
      error.data
    );
    isCaptchaSending.value = false; // 发送失败时也要重置状态
    toast.error(t('auth.forgotPassword.captchaSendError'), {
      description:
        error.data?.message ||
        t('auth.forgotPassword.unknownError')
    });
  }
}

const profileFormSchema = toTypedSchema(
  z
    .object({
      email: z
        .string()
        .email(t('auth.forgotPassword.emailInvalid'))
        .refine(
          email => !verifiedEmails.value.includes(email),
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
      captcha: z.string().optional()
    })
    .refine(
      data => data.newPassword === data.confirmPassword,
      {
        message: t('auth.forgotPassword.passwordMismatch'),
        path: ['confirmPassword'] // 错误提示显示在确认密码字段
      }
    )
);

const { handleSubmit, resetForm } = useForm({
  validationSchema: profileFormSchema,
  initialValues: {
    newPassword: '',
    confirmPassword: '',
    captcha: ''
  }
});

const onSubmit = handleSubmit(async values => {
  try {
    const response = await apiFetch(
      '/api/v1/auth/reset-password',
      {
        method: 'POST',
        body: {
          email: email.value,
          resettoken: value.value.join(''),
          newPassword: values.newPassword
        }
      }
    );
    toast.success(
      'the auth.forgotPassword.resetPasswordSuccess',
      {
        description: t(
          'auth.forgotPassword.resetPasswordSuccessDescription'
        )
      }
    );
  } catch (error: any) {
    console.error(
      t('auth.forgotPassword.resetPasswordError'),
      error.data
    );
    toast.error(
      t('auth.forgotPassword.resetPasswordError'),
      {
        description:
          error.data?.message ||
          t('auth.forgotPassword.unknownError')
      }
    );
  } finally {
    try {
      preferenceStore.resetToDefaults(); // 重置用户偏好设置
      await apiFetch('/api/v1/auth/logout', {
        method: 'GET'
      });
      console.log(
        'User logged out successfully',
        localePath('auth-login')
      );
      // 等待两秒
      setTimeout(() => {
        navigateTo(localePath('auth-login'));
      }, 2000);
    } catch (error) {
      toast.error('退出登录失败，请重试。');
    }
  }
});
</script>

<template>
  <div
    class="w-full lg:grid lg:min-h-[600px] lg:grid-cols-2 xl:min-h-[800px]"
  >
    <div class="flex items-center justify-center py-12">
      <div class="mx-auto grid w-[350px] gap-6">
        <div class="grid gap-2 text-center">
          <h1 class="text-3xl font-bold">
            {{ $t('auth.forgotPassword.title') }}
          </h1>
          <p class="text-balance text-muted-foreground">
            {{
              $t('auth.forgotPassword.forgotPasswordPrompt')
            }}
          </p>
        </div>
        <form class="space-y-8" @submit="onSubmit">
          <FormField
            v-slot="{ componentField }"
            name="email"
          >
            <FormItem>
              <FormLabel>{{
                $t('auth.forgotPassword.email')
              }}</FormLabel>
              <FormControl>
                <Input
                  type="text"
                  :placeholder="
                    $t(
                      'auth.forgotPassword.emailPlaceholder'
                    )
                  "
                  v-bind="componentField"
                  v-model="email"
                  class="pr-10"
                />
              </FormControl>
              <FormDescription>
                {{
                  $t('auth.forgotPassword.emailDescription')
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
                $t('auth.forgotPassword.newPassword')
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
                      $t(
                        'auth.forgotPassword.newPasswordPlaceholder'
                      )
                    "
                    v-bind="componentField"
                    class="pr-10"
                  />
                </FormControl>
                <button
                  type="button"
                  @click="
                    isPasswordVisible = !isPasswordVisible
                  "
                  class="absolute inset-y-0 right-0 flex items-center justify-center h-full px-3 text-muted-foreground"
                >
                  <Eye
                    v-if="!isPasswordVisible"
                    class="size-4"
                  />
                  <EyeOff v-else class="size-4" />
                  <span class="sr-only"
                    >Toggle password visibility</span
                  >
                </button>
              </div>
              <FormDescription>
                {{
                  $t(
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
                $t('auth.forgotPassword.confirmPassword')
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
                      $t(
                        'auth.forgotPassword.confirmPasswordPlaceholder'
                      )
                    "
                    v-bind="componentField"
                    class="pr-10"
                  />
                </FormControl>
                <button
                  type="button"
                  @click="
                    isConfirmPasswordVisible =
                      !isConfirmPasswordVisible
                  "
                  class="absolute inset-y-0 right-0 flex items-center justify-center h-full px-3 text-muted-foreground"
                >
                  <Eye
                    v-if="!isConfirmPasswordVisible"
                    class="size-4"
                  />
                  <EyeOff v-else class="size-4" />
                  <span class="sr-only"
                    >Toggle password visibility</span
                  >
                </button>
              </div>
              <FormDescription>
                {{
                  $t(
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
                $t('auth.forgotPassword.captcha')
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
                <Button
                  type="button"
                  @click="sendCaptcha"
                  :disabled="isCaptchaSending"
                  class="w-32"
                >
                  <!-- 
    使用 v-if 和 v-else 来根据 isCaptchaSending 的状态显示不同的文本
  -->
                  <span v-if="isCaptchaSending">
                    {{ countdown }}
                    {{
                      $t(
                        'auth.forgotPassword.captchaSentSecondDescription'
                      )
                    }}
                  </span>
                  <span v-else>
                    {{
                      $t('auth.forgotPassword.sendCaptcha')
                    }}
                  </span>
                </Button>
              </div>
              <FormMessage />
            </FormItem>
          </FormField>

          <div class="flex gap-2 justify-start">
            <Button type="submit">
              {{ $t('auth.forgotPassword.resetPassword') }}
            </Button>
          </div>
        </form>
        <div class="mt-4 text-center text-sm">
          已拥有账户？
          <NuxtLink
            :to="$localePath('auth-login')"
            class="underline"
          >
            登录
          </NuxtLink>
        </div>
      </div>
    </div>
    <div class="hidden bg-muted lg:block">
      <img
        src="~/public/placeholder.svg"
        alt="Image"
        width="1920"
        height="1080"
        class="h-full w-full object-cover dark:brightness-[0.2] dark:grayscale"
      />
    </div>
  </div>
</template>
