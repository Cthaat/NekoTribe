<script setup lang="ts">
// 无页面布局
definePageMeta({
  layout: false
});

import { ref, watch } from 'vue';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Checkbox } from '@/components/ui/checkbox';
// 1. 导入 useField 来手动控制字段
import { useField } from 'vee-validate';
// 日期选择器相关导入
import {
  DateFormatter,
  type DateValue,
  getLocalTimeZone
} from '@internationalized/date';
import { CalendarIcon } from 'lucide-vue-next';
import { Calendar } from '@/components/ui/calendar';
import {
  Popover,
  PopoverContent,
  PopoverTrigger
} from '@/components/ui/popover';
import { cn } from '@/lib/utils';
import { useI18n } from 'vue-i18n';
import { h } from 'vue';
import * as z from 'zod';
import { toTypedSchema } from '@vee-validate/zod';
import { useForm } from 'vee-validate';
import { toast } from 'vue-sonner';
import { useApiFetch } from '@/composables/useApiFetch'; // 导入自定义的 useApiFetch 组合式 API
import { apiFetch } from '@/composables/useApi';
import { useRouter } from 'vue-router';
import { usePreferenceStore } from '~/stores/user'; // 导入 store
import {
  PinInput,
  PinInputGroup,
  PinInputSlot
} from '@/components/ui/pin-input';
// 从你的 UI 库中导入这些基础表单组件
import {
  FormControl,
  FormField,
  FormItem,
  FormLabel,
  FormMessage
} from '@/components/ui/form';

import { navigateTo } from '#app';

const { t, locale, setLocale } = useI18n();

const description = t('auth.signUp.description');
const iframeHeight = '800px';
const containerClass = 'w-full h-full p-4 lg:p-0';

useHead({
  title: t('auth.signUp.title'),
  meta: [
    {
      name: 'description',
      content: description
    }
  ]
});

// 更新 schema
const formSchema = toTypedSchema(
  z
    .object({
      email: z
        .string()
        .email({ message: t('auth.signUp.emailInvalid') }),
      username: z.string().min(2, {
        message: t('auth.signUp.usernameRequired')
      }),
      displayName: z.string().min(2, {
        message: t('auth.signUp.displayNameRequired')
      }),
      phone: z.string().optional(),
      birthDate: z.any().optional(),
      location: z.string().optional(),
      bio: z.string().optional(),
      password: z.string().min(6, {
        message: t('auth.signUp.passwordTooShort')
      }),
      confirmPassword: z.string().min(6, {
        message: t('auth.signUp.passwordTooShort')
      }),
      captcha: z.string().optional(),
      // 简化 agreeToTerms 的验证逻辑
      agreeToTerms: z
        .boolean()
        .refine(val => val === true, {
          message: t('auth.signUp.termsNotAgreed')
        })
    })
    .refine(
      data => data.password === data.confirmPassword,
      {
        message: t('auth.signUp.passwordMismatch'),
        path: ['confirmPassword'] // 错误提示显示在确认密码字段
      }
    )
);

// 创建表单实例
const form = useForm({
  validationSchema: formSchema,
  initialValues: {
    email: '',
    username: '',
    displayName: '',
    phone: '',
    // 将 birthDate 的初始值设为 `undefined` 或 `null`，而不是空字符串
    // 这与日历组件的期望值类型更匹配
    birthDate: undefined,
    location: '',
    bio: '',
    password: '',
    confirmPassword: '',
    captcha: '',
    agreeToTerms: false // 默认同意服务条款
  }
});

const isLoading = ref(false);

const router = useRouter();

const value = ref<string[]>([]);

// --- 新增：为验证码按钮添加状态 ---
const isCaptchaSending = ref(false);
const countdown = ref(60);
let timer: ReturnType<typeof setInterval> | null = null; // 用于存储定时器实例

async function sendCaptcha() {
  const { valid, errors } =
    await form.validateField('email');
  if (!valid) {
    toast.error(t('auth.signUp.captchaSendError'), {
      description:
        errors[0] || t('auth.signUp.emailInvalid')
    });
    return;
  }
  // 获取邮箱
  const email = form.values.email;

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

// 在组件卸载时清除定时器，防止内存泄漏 (最佳实践)
import { onUnmounted } from 'vue';
onUnmounted(() => {
  if (timer) {
    clearInterval(timer);
  }
});

async function onValidSubmit(values: Record<string, any>) {
  isLoading.value = true;

  values.captcha = value.value.join('');

  try {
    // 1. 调用 API，等待它完成
    const response: any = await apiFetch(
      '/api/v1/auth/register',
      {
        method: 'POST',
        body: values
      }
    );

    console.log(t('auth.signUp.successRegister'), values);

    // 2. 成功后，唯一要做的就是导航！
    //    使用 await 确保导航被正确触发。
    //    让中间件和目标页面去担心登录状态。
    toast(t('auth.signUp.successRegister'), {
      description: t('auth.signUp.redirectToLogin')
    });
    console.log(
      t('auth.signUp.successRegisterDescription'),
      response
    );
    await navigateTo('/auth/login');
  } catch (error: any) {
    // 错误处理逻辑保持不变
    console.error(
      t('auth.signUp.registerFailed'),
      error.data
    );
    toast.error(t('auth.signUp.registerFailed'), {
      description:
        error.data?.message || t('auth.signUp.unknownError')
    });
  } finally {
    isLoading.value = false;
  }
}

// 创建日期格式化实例，这部分是正确的
const df = new DateFormatter(
  locale.value === 'cn' ? 'zh-CN' : 'en-US',
  {
    dateStyle: 'long'
  }
);

// 4. 创建最终的 onSubmit 函数，它会先验证再决定是否执行 onValidSubmit
const onSubmit = form.handleSubmit(onValidSubmit);

// 手动管理 agreeToTerms 状态
const agreeToTermsValue = ref(false);

// 监听变化并同步到表单
watch(agreeToTermsValue, newValue => {
  console.log(
    t('auth.signUp.agreeToTermsChanged'),
    newValue
  );
  form.setFieldValue('agreeToTerms', newValue);
});

// 添加一个点击处理函数来调试
const handleCheckboxChange = (checked: boolean) => {
  console.log(
    t('auth.signUp.agreeToTermsChanged'),
    checked
  );
  agreeToTermsValue.value = checked;
};
</script>

<template>
  <div
    class="w-full lg:grid lg:min-h-[600px] lg:grid-cols-2 xl:min-h-[800px]"
  >
    <div class="flex items-center justify-center py-12">
      <!-- 使用 vee-validate 的 handleSubmit 进行提交，它会先执行验证 -->
      <form
        class="mx-auto grid w-[400px] gap-6"
        @submit="onSubmit"
      >
        <div class="grid gap-2 text-center">
          <h1 class="text-3xl font-bold">
            {{ $t('auth.signUp.signUpPrompt') }}
          </h1>
          <p class="text-balance text-muted-foreground">
            {{ $t('auth.signUp.signUpPromptDescription') }}
          </p>
        </div>

        <div class="grid gap-4">
          <!-- 邮箱地址 (单列) -->
          <FormField
            v-slot="{ componentField }"
            name="email"
          >
            <FormItem>
              <FormLabel>{{
                $t('auth.signUp.email')
              }}</FormLabel>
              <FormControl>
                <Input
                  id="email"
                  type="email"
                  placeholder="m@example.com"
                  v-bind="componentField"
                />
              </FormControl>
              <FormMessage />
            </FormItem>
          </FormField>

          <!-- 两列布局区域 -->
          <div class="grid grid-cols-2 gap-4">
            <!-- 用户名 -->
            <FormField
              v-slot="{ componentField }"
              name="username"
            >
              <FormItem>
                <FormLabel>{{
                  $t('auth.signUp.username')
                }}</FormLabel>
                <FormControl>
                  <Input
                    id="username"
                    type="text"
                    :placeholder="
                      $t('auth.signUp.usernamePlaceholder')
                    "
                    v-bind="componentField"
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            </FormField>

            <!-- 显示名称 -->
            <FormField
              v-slot="{ componentField }"
              name="displayName"
            >
              <FormItem>
                <FormLabel>{{
                  $t('auth.signUp.displayName')
                }}</FormLabel>
                <FormControl>
                  <Input
                    id="displayName"
                    type="text"
                    :placeholder="
                      $t(
                        'auth.signUp.displayNamePlaceholder'
                      )
                    "
                    v-bind="componentField"
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            </FormField>

            <!-- 手机号 -->
            <FormField
              v-slot="{ componentField }"
              name="phone"
            >
              <FormItem>
                <FormLabel>{{
                  $t('auth.signUp.phone')
                }}</FormLabel>
                <FormControl>
                  <Input
                    id="phone"
                    type="tel"
                    :placeholder="
                      $t('auth.signUp.phonePlaceholder')
                    "
                    v-bind="componentField"
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            </FormField>

            <!-- 生日 (日历选择器) -->
            <FormField
              v-slot="{ componentField, value }"
              name="birthDate"
            >
              <FormItem>
                <FormLabel>{{
                  $t('auth.signUp.birthDate')
                }}</FormLabel>
                <Popover>
                  <PopoverTrigger as-child>
                    <FormControl>
                      <!-- 
            这个按钮是用户看到的界面，它的作用是触发弹窗。
            它的文本内容会根据当前是否有值 (value) 来动态显示。
          -->
                      <Button
                        variant="outline"
                        :class="
                          cn(
                            'w-full justify-start text-left font-normal',
                            !value &&
                              'text-muted-foreground'
                          )
                        "
                      >
                        <CalendarIcon
                          class="mr-2 h-4 w-4"
                        />
                        <!-- 
              三元表达式用于显示日期：
              - 如果 `value` 存在，就使用日期格式化工具 `df` 来显示。
              - 注意：日历组件返回的是一个特殊的日期对象，需要用 `.toDate(getLocalTimeZone())` 转换成标准 JS Date 对象才能格式化。
              - 如果 `value` 不存在，就显示占位符文本。
            -->
                        {{
                          value
                            ? df.format(
                                value.toDate(
                                  getLocalTimeZone()
                                )
                              )
                            : $t(
                                'auth.signUp.birthDatePlaceholder'
                              )
                        }}
                      </Button>
                    </FormControl>
                  </PopoverTrigger>
                  <PopoverContent class="w-auto p-0">
                    <!-- 
          这是核心部分：
          `v-bind="componentField"` 是一个语法糖，它将 vee-validate 的状态
          (包括 value, onBlur, onInput/onChange 事件) 自动绑定到 <Calendar> 组件上。
          这使得用户在日历中选择日期时，表单状态会自动更新。
        -->
                    <Calendar
                      v-bind="componentField"
                      initial-focus
                    />
                  </PopoverContent>
                </Popover>
                <FormMessage />
              </FormItem>
            </FormField>

            <!-- 所在地 -->
            <FormField
              v-slot="{ componentField }"
              name="location"
            >
              <FormItem>
                <FormLabel>{{
                  $t('auth.signUp.location')
                }}</FormLabel>
                <FormControl>
                  <Input
                    id="location"
                    type="text"
                    :placeholder="
                      $t('auth.signUp.locationPlaceholder')
                    "
                    v-bind="componentField"
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            </FormField>
          </div>

          <!-- 简介 (单列) -->
          <FormField v-slot="{ componentField }" name="bio">
            <FormItem>
              <FormLabel>{{
                $t('auth.signUp.bio')
              }}</FormLabel>
              <FormControl>
                <Input
                  id="bio"
                  type="text"
                  :placeholder="
                    $t('auth.signUp.bioPlaceholder')
                  "
                  v-bind="componentField"
                />
              </FormControl>
              <FormMessage />
            </FormItem>
          </FormField>

          <!-- 密码区域 (两列) -->
          <div class="grid grid-cols-2 gap-4">
            <!-- 密码 -->
            <FormField
              v-slot="{ componentField }"
              name="password"
            >
              <FormItem>
                <FormLabel>{{
                  $t('auth.signUp.password')
                }}</FormLabel>
                <FormControl>
                  <Input
                    id="password"
                    type="password"
                    :placeholder="
                      $t('auth.signUp.passwordPlaceholder')
                    "
                    v-bind="componentField"
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            </FormField>

            <!-- 确认密码 -->
            <FormField
              v-slot="{ componentField }"
              name="confirmPassword"
            >
              <FormItem>
                <FormLabel>{{
                  $t('auth.signUp.confirmPassword')
                }}</FormLabel>
                <FormControl>
                  <Input
                    id="confirmPassword"
                    type="password"
                    :placeholder="
                      $t(
                        'auth.signUp.confirmPasswordPlaceholder'
                      )
                    "
                    v-bind="componentField"
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            </FormField>
          </div>

          <!-- 验证码和服务条款区域 (两列) -->
          <FormField
            v-slot="{ componentField }"
            name="captcha"
          >
            <FormItem>
              <FormLabel>{{
                $t('auth.signUp.captcha')
              }}</FormLabel>
              <!-- 
      使用一个 div 作为 Flexbox 容器，
      它将包裹输入框和按钮，让它们在同一行显示。
    -->
              <div class="flex w-full items-center gap-x-2">
                <FormControl>
                  <!-- 
          flex-1 是关键，它告诉输入框：
          "占据所有可用的剩余空间"。
        -->
                  <PinInput
                    class="flex-1"
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
        type="button" 很重要，可以防止它意外触发表单提交。
      -->
                <Button
                  type="button"
                  @click="sendCaptcha"
                  :disabled="isCaptchaSending"
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

          <div>
            <!-- 服务条款 (复选框) -->
            <FormField name="agreeToTerms">
              <FormItem
                class="flex flex-row items-center gap-x-2 mt-6"
              >
                <FormControl>
                  <!-- 使用原生的 v-model -->
                  <Checkbox v-model="agreeToTermsValue" />
                </FormControl>
                <div class="grid gap-1.5 leading-none">
                  <FormLabel
                    class="text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-70"
                  >
                    {{ $t('auth.signUp.agreeToTerms') }}
                    <NuxtLink
                      :to="$localePath('/auth/terms')"
                      class="underline text-blue-600"
                    >
                      {{ $t('auth.signUp.termsLink') }}
                    </NuxtLink>
                  </FormLabel>
                </div>
              </FormItem>
              <FormMessage />
            </FormField>
          </div>

          <Button type="submit" class="w-full mt-2">{{
            $t('auth.signUp.signUpButton')
          }}</Button>
        </div>

        <div class="mt-4 text-center text-sm">
          {{ $t('auth.signUp.haveAccount') }}<br />
          <NuxtLink
            :to="$localePath('/auth/login')"
            class="underline"
          >
            {{ $t('auth.signUp.loginPrompt') }}
          </NuxtLink>
        </div>
      </form>
    </div>
    <div class="hidden bg-muted lg:block">
      <img
        src="/placeholder.svg"
        alt="Image"
        width="1920"
        height="1080"
        class="h-full w-full object-cover dark:brightness-[0.2] dark:grayscale"
      />
    </div>
  </div>
</template>
