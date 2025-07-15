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

const { t, locale, setLocale } = useI18n();

const userInfo = ref({
  displayName: '',
  bio: '',
  location: '',
  urls: [{ value: '' }],
  birthDate: null as DateValue | null,
  phone: ''
});

onMounted(async () => {
  try {
    const response = (await apiFetch('/api/v1/users/me', {
      method: 'GET'
    })) as { data?: { userData?: { userInfo?: any } } };

    userInfo.value = response.data?.userData?.userInfo;

    console.log('Fetched user info:', userInfo);

    let birth: any = userInfo.value.birthDate;

    // 检查 userInfo 是否存在
    if (userInfo.value) {
      // 使用 resetForm 将获取到的数据填充到表单中**
      resetForm({
        values: {
          displayName: userInfo.value.displayName || '',
          bio: userInfo.value.bio || '',
          location: userInfo.value.location || '',
          // 确保 urls 的格式是 [{ value: '...' }]
          // 如果 API 返回的 urls 为空或 null，则提供一个默认的空 URL 字段
          urls:
            userInfo.value.urls &&
            userInfo.value.urls.length > 0
              ? userInfo.value.urls
              : [{ value: '' }],
          // 对于日历组件，最好将日期字符串转换为 DateValue 对象
          // 假设 API 返回的 birthDate 是 'YYYY-MM-DD' 格式的字符串
          birthDate: userInfo.value.birthDate
            ? parseDate(birth.split('T')[0])
            : undefined,
          phone: userInfo.value.phone || ''
        }
      });
    }
  } catch (error) {
    console.error('Error fetching user info:', error);
    toast.error('Failed to fetch user info.');
  }
});

const profileFormSchema = toTypedSchema(
  z.object({
    displayName: z
      .string()
      .min(2, {
        message:
          'DisplayName must be at least 2 characters.'
      })
      .max(30, {
        message:
          'DisplayName must not be longer than 30 characters.'
      }),
    bio: z
      .string()
      .max(160, {
        message:
          'Bio must not be longer than 160 characters.'
      })
      .min(4, {
        message: 'Bio must be at least 2 characters.'
      }),
    location: z.string().max(30, {
      message:
        'Location must not be longer than 30 characters.'
    }),
    urls: z.array(
      z.object({
        value: z.string().optional()
      })
    ),
    birthDate: z.any().optional(),
    phone: z.string().optional()
  })
);

let birth: any = userInfo.value.birthDate || null;
const { handleSubmit, resetForm } = useForm({
  validationSchema: profileFormSchema,
  initialValues: {
    displayName: userInfo.value.displayName || '',
    bio: userInfo.value.bio || '',
    location: userInfo.value.location || '',
    // 确保 urls 的格式是 [{ value: '...' }]
    // 如果 API 返回的 urls 为空或 null，则提供一个默认的空 URL 字段
    urls:
      userInfo.value.urls && userInfo.value.urls.length > 0
        ? userInfo.value.urls
        : [{ value: '' }],
    // 对于日历组件，最好将日期字符串转换为 DateValue 对象
    // 假设 API 返回的 birthDate 是 'YYYY-MM-DD' 格式的字符串
    birthDate: userInfo.value.birthDate
      ? parseDate(birth.split('T')[0])
      : undefined,
    phone: userInfo.value.phone || ''
  }
});

const onSubmit = handleSubmit(values => {
  toast({
    title: 'You submitted the following values:'
  });
});

// 创建日期格式化实例，这部分是正确的
const df = new DateFormatter(
  locale.value === 'cn' ? 'zh-CN' : 'en-US',
  {
    dateStyle: 'long'
  }
);
</script>

<template>
  <form class="space-y-8" @submit="onSubmit">
    <FormField
      v-slot="{ componentField }"
      name="displayName"
    >
      <FormItem>
        <FormLabel>DisplayName</FormLabel>
        <FormControl>
          <Input
            type="text"
            placeholder="displayName"
            v-bind="componentField"
          />
        </FormControl>
        <FormDescription>
          This is your public display name. It can be your
          real name or a pseudonym.
        </FormDescription>
        <FormMessage />
      </FormItem>
    </FormField>

    <FormField v-slot="{ componentField }" name="bio">
      <FormItem>
        <FormLabel>Bio</FormLabel>
        <FormControl>
          <Textarea
            placeholder="Tell us a little bit about yourself"
            v-bind="componentField"
          />
        </FormControl>
        <FormDescription>
          You can <span>@mention</span> other users and
          organizations to link to them.
        </FormDescription>
        <FormMessage />
      </FormItem>
    </FormField>

    <FormField v-slot="{ componentField }" name="location">
      <FormItem>
        <FormLabel>Location</FormLabel>
        <FormControl>
          <Textarea
            placeholder="Where are you located?"
            v-bind="componentField"
          />
        </FormControl>
        <FormDescription>
          This is optional, but it helps others to know
          where you are based.
        </FormDescription>
        <FormMessage />
      </FormItem>
    </FormField>

    <div>
      <FieldArray v-slot="{ fields, push }" name="urls">
        <div
          v-for="(field, index) in fields"
          :key="`urls-${field.key}`"
        >
          <FormField
            v-slot="{ componentField }"
            :name="`urls[${index}].value`"
          >
            <FormItem>
              <FormLabel
                :class="cn(index !== 0 && 'sr-only')"
              >
                URLs
              </FormLabel>
              <FormDescription
                :class="cn(index !== 0 && 'sr-only')"
              >
                Add links to your website, blog, or social
                media profiles.
              </FormDescription>
              <div class="relative flex items-center">
                <FormControl>
                  <Input
                    type="url"
                    v-bind="componentField"
                  />
                </FormControl>
              </div>
              <FormMessage />
            </FormItem>
          </FormField>
        </div>

        <Button
          type="button"
          variant="outline"
          size="sm"
          class="text-xs w-20 mt-2"
          @click="push({ value: '' })"
        >
          Add URL
        </Button>
      </FieldArray>
    </div>

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
                    !value && 'text-muted-foreground'
                  )
                "
              >
                <CalendarIcon class="mr-2 h-4 w-4" />
                <!-- 
              三元表达式用于显示日期：
              - 如果 `value` 存在，就使用日期格式化工具 `df` 来显示。
              - 注意：日历组件返回的是一个特殊的日期对象，需要用 `.toDate(getLocalTimeZone())` 转换成标准 JS Date 对象才能格式化。
              - 如果 `value` 不存在，就显示占位符文本。
            -->
                {{
                  value
                    ? df.format(
                        value.toDate(getLocalTimeZone())
                      )
                    : $t('auth.signUp.birthDatePlaceholder')
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

    <FormField v-slot="{ componentField }" name="phone">
      <FormItem>
        <FormLabel>Phone</FormLabel>
        <FormControl>
          <Textarea
            placeholder="Enter your phone number"
            v-bind="componentField"
          />
        </FormControl>
        <FormDescription>
          This is optional, but it helps others to contact
          you.
        </FormDescription>
        <FormMessage />
      </FormItem>
    </FormField>

    <div class="flex gap-2 justify-start">
      <Button type="submit"> Update profile </Button>

      <Button
        type="button"
        variant="outline"
        @click="resetForm"
      >
        Reset form
      </Button>
    </div>
  </form>
</template>
