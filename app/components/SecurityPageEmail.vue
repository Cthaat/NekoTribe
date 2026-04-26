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

const preferenceStore = usePreferenceStore();

const { t } = useI18n();

const localePath = useLocalePath();

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

    toast.success(
      t('account.security.securityPage.email.captchaSent'),
      {
        description: t(
          'account.security.securityPage.email.captchaSentDescription'
        )
      }
    );

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
      t(
        'account.security.securityPage.email.captchaSendError'
      ),
      error.data
    );
    toast.error(
      t(
        'account.security.securityPage.email.captchaSendError'
      ),
      {
        description:
          error.data?.message ||
          t(
            'account.security.securityPage.email.unknownError'
          )
      }
    );
  }
}

const profileFormSchema = toTypedSchema(
  z.object({
    email: z
      .string()
      .email(
        t(
          'account.security.securityPage.email.emailInvalid'
        )
      ),
    captcha: z.string().optional()
  })
);

const { handleSubmit, resetForm } = useForm({
  validationSchema: profileFormSchema,
  initialValues: {
    email: '',
    captcha: ''
  }
});

const onSubmit = handleSubmit(async values => {
  try {
    const response = await apiFetch(
      '/api/v1/users/me/email',
      {
        method: 'PUT',
        body: {
          newEmail: values.email,
          resettoken: value.value.join('')
        }
      }
    );
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
  } catch (error: any) {
    console.error(
      t(
        'account.security.securityPage.email.emailChangeError'
      ),
      error.data
    );
    toast.error(
      t('account.security.securityPage.email.unknownError'),
      {
        description:
          error.data?.message ||
          t(
            'account.security.securityPage.email.unknownError'
          )
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
      toast.error(
        t('account.security.securityPage.email.logoutError')
      );
    }
  }
});
</script>

<template>
  <form class="space-y-8" @submit="onSubmit">
    <FormField v-slot="{ componentField }" name="email">
      <FormItem>
        <FormLabel>{{
          $t(
            'account.security.securityPage.email.emailLabel'
          )
        }}</FormLabel>
        <FormControl>
          <Input
            type="text"
            :placeholder="
              $t(
                'account.security.securityPage.email.emailPlaceholder'
              )
            "
            v-bind="componentField"
            class="pr-10"
          />
        </FormControl>
        <FormDescription>
          {{
            $t(
              'account.security.securityPage.email.emailDescription'
            )
          }}
        </FormDescription>
        <FormMessage />
      </FormItem>
    </FormField>

    <!-- 验证码和服务条款区域 (两列) -->
    <FormField v-slot="{ componentField }" name="captcha">
      <FormItem>
        <FormLabel>{{
          $t(
            'account.security.securityPage.email.captchaLabel'
          )
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
              {{
                countdown +
                t(
                  'account.security.securityPage.email.secondsLeft'
                )
              }}
            </span>
            <span v-else>
              {{
                $t(
                  'account.security.securityPage.email.sendCaptcha'
                )
              }}
            </span>
          </Button>
        </div>
        <FormMessage />
      </FormItem>
    </FormField>

    <div class="flex gap-2 justify-start">
      <Button type="submit">
        {{
          $t(
            'account.security.securityPage.email.updateButton'
          )
        }}
      </Button>
    </div>
  </form>
</template>
