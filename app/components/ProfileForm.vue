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
import {
  v2GetMe,
  v2PatchMe,
  type CurrentUserVM
} from '@/services';

const verifiedEmails = ref([
  'm@example.com',
  'm@google.com',
  'm@support.com'
]);

const { t, locale } = useAppLocale();

const userInfo = ref<CurrentUserVM | null>(null);

interface ProfileUrlItem {
  value: string;
}

interface ProfileFormValues {
  displayName: string;
  bio: string;
  location: string;
  urls: ProfileUrlItem[];
  birthDate?: DateValue;
  phone: string;
}

function mapWebsiteToUrls(
  website: string
): ProfileUrlItem[] {
  if (!website.trim()) {
    return [{ value: '' }];
  }

  return website
    .split(',')
    .map(url => ({ value: url.trim() }))
    .filter(item => item.value.length > 0);
}

function parseBirthDate(
  birthDate: string | null
): DateValue | undefined {
  if (!birthDate) {
    return undefined;
  }

  return parseDate(birthDate.split('T')[0]);
}

function buildInitialProfileValues(
  user: CurrentUserVM | null
): ProfileFormValues {
  return {
    displayName: user?.name || '',
    bio: user?.bio || '',
    location: user?.location || '',
    urls: mapWebsiteToUrls(user?.website || ''),
    birthDate: parseBirthDate(user?.birthDate || null),
    phone: user?.phone || ''
  };
}

onMounted(async () => {
  try {
    const me = await v2GetMe();
    userInfo.value = me;

    // 检查 userInfo 是否存在
    if (userInfo.value) {
      resetForm({
        values: buildInitialProfileValues(userInfo.value)
      });
    }
  } catch (error) {
    console.error(
      t('account.profile.profilePage.errorFetchingUserInfo'),
      error
    );
    toast.error(
      t(
        'account.profile.profilePage.errorFetchingUserInfo'
      ),
      {
        description: t(
          'account.profile.profilePage.errorFetchingUserInfoDescription'
        ),
        duration: 5000
      }
    );
  }
});

const profileFormSchema = z.object({
  displayName: z
    .string()
    .trim()
    .min(2, {
      message: t(
        'account.profile.profilePage.displayNameMinLength'
      )
    })
    .max(30, {
      message: t(
        'account.profile.profilePage.displayNameMaxLength'
      )
    }),
  bio: z
    .string()
    .trim()
    .max(160, {
      message: t(
        'account.profile.profilePage.bioMaxLength'
      )
    })
    .min(4, {
      message: t(
        'account.profile.profilePage.bioMinLength'
      )
    }),
  location: z.string().trim().max(30, {
    message: t(
      'account.profile.profilePage.locationMaxLength'
    )
  }),
  urls: z.array(
    z.object({
      value: z.string()
    })
  ),
  birthDate: z.custom<DateValue>().optional(),
  phone: z.string()
});

const { handleSubmit, resetForm } =
  useForm<ProfileFormValues>({
    validationSchema: toTypedSchema(profileFormSchema),
    initialValues: buildInitialProfileValues(userInfo.value)
  });

const onSubmit = handleSubmit(
  async (values: ProfileFormValues): Promise<void> => {
  let website = '';

  website = values.urls
    .map(urlObject => urlObject.value.trim())
    .filter(url => url.length > 0)
    .join(',');
  const payload = {
    displayName: values.displayName,
    bio: values.bio,
    location: values.location,
    website,
    birthDate: values.birthDate
      ? values.birthDate.toString()
      : null,
    phone: values.phone || undefined
  };
  toast(t('account.profile.profilePage.successMessage'), {
    description: t(
      'account.profile.profilePage.successDescription'
    ),
    duration: 3000
  });
  await v2PatchMe(payload);
  // 刷新页面
  if (process.client) {
    window.location.reload();
  }
  }
);

// 创建日期格式化实例，这部分是正确的
const df = new DateFormatter(
  locale.value === 'zh' ? 'zh-CN' : 'en-US',
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
        <FormLabel>{{
          t('account.profile.profilePage.displayName')
        }}</FormLabel>
        <FormControl>
          <Input
            type="text"
            :placeholder="
              t(
                'account.profile.profilePage.displayNamePlaceholder'
              )
            "
            v-bind="componentField"
          />
        </FormControl>
        <FormDescription>
          {{
            t(
              'account.profile.profilePage.displayNameDescription'
            )
          }}
        </FormDescription>
        <FormMessage />
      </FormItem>
    </FormField>

    <FormField v-slot="{ componentField }" name="bio">
      <FormItem>
        <FormLabel>{{
          t('account.profile.profilePage.bio')
        }}</FormLabel>
        <FormControl>
          <Textarea
            :placeholder="
              t(
                'account.profile.profilePage.bioPlaceholder'
              )
            "
            v-bind="componentField"
          />
        </FormControl>
        <FormDescription>
          {{
            t(
              'account.profile.profilePage.bioDescription',
              { atSign: '@' }
            )
          }}
        </FormDescription>
        <FormMessage />
      </FormItem>
    </FormField>

    <FormField v-slot="{ componentField }" name="location">
      <FormItem>
        <FormLabel>{{
          t('account.profile.profilePage.location')
        }}</FormLabel>
        <FormControl>
          <Textarea
            :placeholder="
              t(
                'account.profile.profilePage.locationPlaceholder'
              )
            "
            v-bind="componentField"
          />
        </FormControl>
        <FormDescription>
          {{
            t(
              'account.profile.profilePage.locationDescription'
            )
          }}
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
                {{
                  t('account.profile.profilePage.website')
                }}
              </FormLabel>
              <FormDescription
                :class="cn(index !== 0 && 'sr-only')"
              >
                {{
                  t(
                    'account.profile.profilePage.websiteDescription'
                  )
                }}
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
          {{ t('account.profile.profilePage.addWebsite') }}
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
          t('auth.signUp.birthDate')
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
                    : t('auth.signUp.birthDatePlaceholder')
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
        <FormLabel>{{
          t('account.profile.profilePage.phone')
        }}</FormLabel>
        <FormControl>
          <Textarea
            :placeholder="
              t(
                'account.profile.profilePage.phonePlaceholder'
              )
            "
            v-bind="componentField"
          />
        </FormControl>
        <FormDescription>
          {{
            t(
              'account.profile.profilePage.phoneDescription'
            )
          }}
        </FormDescription>
        <FormMessage />
      </FormItem>
    </FormField>

    <div class="flex gap-2 justify-start">
      <Button type="submit">
        {{
          t('account.profile.profilePage.updateProfile')
        }}
      </Button>

      <Button
        type="button"
        variant="outline"
        @click="resetForm"
      >
        {{ t('account.profile.profilePage.resetForm') }}
      </Button>
    </div>
  </form>
</template>


