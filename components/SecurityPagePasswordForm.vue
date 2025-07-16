<script setup lang="ts">
import { toTypedSchema } from '@vee-validate/zod';
import { FieldArray, useForm } from 'vee-validate';
import { h, ref } from 'vue';
import * as z from 'zod';
import { cn } from '@/lib/utils';
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

const preferenceStore = usePreferenceStore();

const { t } = useI18n();

const value = ref<string[]>([]);

// --- 新增：为验证码按钮添加状态 ---
const isCaptchaSending = ref(false);
const countdown = ref(60);
let timer: ReturnType<typeof setInterval> | null = null; // 用于存储定时器实例

async function sendCaptcha() {
  const email = preferenceStore.preferences.user.email;

  // 2. 进入发送状态，禁用按钮
  isCaptchaSending.value = true;
  countdown.value = 60; // 重置倒计时

  try {
    // 1. 调用 API，等待它完成
    const response: any = await apiFetch(
      '/api/v1/auth/get-verification',
      {
        method: 'POST',
        body: {
          account: email
        }
      }
    );
    console.log(response);

    toast.success('the auth.signUp.captchaSent', {
      description: t('auth.signUp.captchaSentDescription')
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
      t('auth.signUp.captchaSendError'),
      error.data
    );
    toast.error(t('auth.signUp.captchaSendError'), {
      description:
        error.data?.message || t('auth.signUp.unknownError')
    });
  }
}

const profileFormSchema = toTypedSchema(
  z
    .object({
      password: z.string().min(6, {
        message: t('auth.signUp.passwordTooShort')
      }),
      confirmPassword: z.string().min(6, {
        message: t('auth.signUp.passwordTooShort')
      }),
      captcha: z.string().optional()
    })
    .refine(
      data => data.password === data.confirmPassword,
      {
        message: t('auth.signUp.passwordMismatch'),
        path: ['confirmPassword'] // 错误提示显示在确认密码字段
      }
    )
);

const { handleSubmit, resetForm } = useForm({
  validationSchema: profileFormSchema,
  initialValues: {
    password: '',
    confirmPassword: '',
    captcha: ''
  }
});

const onSubmit = handleSubmit(async values => {});
</script>

<template>
  <form class="space-y-8" @submit="onSubmit">
    <FormField
      v-slot="{ componentField }"
      name="newPassword"
    >
      <FormItem>
        <FormLabel>New Password</FormLabel>
        <FormControl>
          <Input
            type="text"
            placeholder="New Password"
            v-bind="componentField"
          />
        </FormControl>
        <FormDescription>
          Your new password must be at least 8 characters
          long.
        </FormDescription>
        <FormMessage />
      </FormItem>
    </FormField>

    <FormField
      v-slot="{ componentField }"
      name="confirmPassword"
    >
      <FormItem>
        <FormLabel>Confirm Password</FormLabel>
        <FormControl>
          <Input
            type="text"
            placeholder="Confirm Password"
            v-bind="componentField"
          />
        </FormControl>
        <FormDescription>
          Your confirm password must be at least 8
          characters long.
        </FormDescription>
        <FormMessage />
      </FormItem>
    </FormField>

    <!-- 验证码和服务条款区域 (两列) -->
    <FormField v-slot="{ componentField }" name="captcha">
      <FormItem>
        <FormLabel>{{
          $t('auth.signUp.captcha')
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
              {{ countdown }} 秒后重试
            </span>
            <span v-else>
              {{ $t('auth.signUp.sendCaptcha') }}
            </span>
          </Button>
        </div>
        <FormMessage />
      </FormItem>
    </FormField>

    <div class="flex gap-2 justify-start">
      <Button type="submit"> Update profile </Button>
    </div>
  </form>
</template>
