<script setup lang="ts">
import { toTypedSchema } from '@vee-validate/zod';
import { FieldArray, useForm } from 'vee-validate';
import { onMounted, onUnmounted, ref } from 'vue';
import { useNuxtApp } from '#app';
import { authQueueFor } from '@/services/auth-request-queue';
import * as z from 'zod/v3';
import { cn } from '@/lib/utils';
import { CalendarIcon, Globe, Trash2 } from 'lucide-vue-next';
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
import { Textarea } from '@/components/ui/textarea';
import { toast } from 'vue-sonner';
import {
  v2GetMe,
  v2PatchMe,
  type CurrentUserVM
} from '@/services';

const { t, locale } = useAppLocale();

const userInfo = ref<CurrentUserVM | null>(null);
const saving = ref(false);
const queue = authQueueFor(useNuxtApp());
const ownerRevision = queue.revision;
let disposed = false;
onUnmounted(() => { disposed = true; });
function ownsForm() {
  return !disposed && ownerRevision === queue.revision && !queue.isIdentityChanging;
}

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

  const date = birthDate.split('T')[0];
  return date ? parseDate(date) : undefined;
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
    if (!ownsForm()) return;
    if (!Number.isSafeInteger(me.id) || me.id <= 0) throw new Error('Invalid profile');
    resetForm({ values: buildInitialProfileValues(me) });
    userInfo.value = me;
  } catch {
    if (!ownsForm()) return;
    toast.error(
      t('account.profile.profilePage.errorFetchingUserInfo'),
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
      message: t('account.profile.profilePage.bioMaxLength')
    })
    .refine(value => value.length === 0 || value.length >= 4, {
      message: t('account.profile.profilePage.bioMinLength')
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
    const owner = userInfo.value;
    if (!owner || saving.value || !ownsForm()) return;
    const website = values.urls
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
      phone: values.phone
    };
    saving.value = true;
    try {
      const updated = await v2PatchMe(payload);
      if (!ownsForm()) return;
      if (updated.id !== owner.id) throw new Error('Invalid profile update response');
      toast.success(t('account.profile.profilePage.successMessage'));
      if (import.meta.client) window.location.reload();
    } catch {
      if (ownsForm()) toast.error(t('account.profile.profilePage.saveFailed'));
    } finally {
      if (ownsForm()) saving.value = false;
    }
  }
);

const df = new DateFormatter(
  locale.value === 'zh' ? 'zh-CN' : 'en-US',
  { dateStyle: 'long' }
);
</script>

<template>
  <form class="grid gap-5" @submit="onSubmit">
    <FormField v-slot="{ componentField }" name="displayName">
      <FormItem class="grid gap-2">
        <FormLabel class="text-xs font-medium">
          {{ t('account.profile.profilePage.displayName') }}
        </FormLabel>
        <FormControl>
          <Input
            type="text"
            :placeholder="
              t(
                'account.profile.profilePage.displayNamePlaceholder'
              )
            "
            v-bind="componentField"
            class="h-9 shadow-xs"
          />
        </FormControl>
        <FormDescription class="text-[11px] text-muted-foreground">
          {{
            t(
              'account.profile.profilePage.displayNameDescription'
            )
          }}
        </FormDescription>
        <FormMessage class="text-[11px]" />
      </FormItem>
    </FormField>

    <FormField v-slot="{ componentField }" name="bio">
      <FormItem class="grid gap-2">
        <FormLabel class="text-xs font-medium">
          {{ t('account.profile.profilePage.bio') }}
        </FormLabel>
        <FormControl>
          <Textarea
            :placeholder="
              t('account.profile.profilePage.bioPlaceholder')
            "
            v-bind="componentField"
            class="min-h-[96px] resize-none rounded-md shadow-xs"
          />
        </FormControl>
        <FormDescription class="text-[11px] text-muted-foreground">
          {{
            t(
              'account.profile.profilePage.bioDescription',
              { atSign: '@' }
            )
          }}
        </FormDescription>
        <FormMessage class="text-[11px]" />
      </FormItem>
    </FormField>

    <FormField v-slot="{ componentField }" name="location">
      <FormItem class="grid gap-2">
        <FormLabel class="text-xs font-medium">
          {{ t('account.profile.profilePage.location') }}
        </FormLabel>
        <FormControl>
          <Input
            type="text"
            :placeholder="
              t(
                'account.profile.profilePage.locationPlaceholder'
              )
            "
            v-bind="componentField"
            class="h-9 shadow-xs"
          />
        </FormControl>
        <FormDescription class="text-[11px] text-muted-foreground">
          {{
            t(
              'account.profile.profilePage.locationDescription'
            )
          }}
        </FormDescription>
        <FormMessage class="text-[11px]" />
      </FormItem>
    </FormField>

    <FieldArray v-slot="{ fields, push, remove }" name="urls">
      <div class="grid gap-2">
        <div class="flex items-center gap-2">
          <Globe class="h-3.5 w-3.5 text-muted-foreground" />
          <span class="text-xs font-medium">
            {{ t('account.profile.profilePage.website') }}
          </span>
        </div>
        <p class="text-[11px] text-muted-foreground">
          {{
            t(
              'account.profile.profilePage.websiteDescription'
            )
          }}
        </p>
        <div class="grid gap-2">
          <FormField
            v-for="(field, index) in fields"
            :key="`urls-${field.key}`"
            v-slot="{ componentField }"
            :name="`urls[${index}].value`"
          >
            <FormItem class="grid gap-1.5">
              <div class="flex items-center gap-2">
                <FormControl>
                  <Input
                    type="url"
                    placeholder="https://"
                    v-bind="componentField"
                    class="h-9 shadow-xs"
                  />
                </FormControl>
                <button
                  v-if="fields.length > 1"
                  type="button"
                  class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md text-muted-foreground transition hover:bg-destructive/10 hover:text-destructive"
                  :aria-label="t('common.remove')"
                  @click="remove(index)"
                >
                  <Trash2 class="h-3.5 w-3.5" />
                </button>
              </div>
              <FormMessage class="text-[11px]" />
            </FormItem>
          </FormField>
        </div>
        <Button
          type="button"
          variant="outline"
          size="sm"
          class="h-8 w-fit rounded-md shadow-xs"
          @click="push({ value: '' })"
        >
          {{ t('account.profile.profilePage.addWebsite') }}
        </Button>
      </div>
    </FieldArray>

    <FormField
      v-slot="{ componentField, value, handleChange }"
      name="birthDate"
    >
      <FormItem class="grid gap-2">
        <FormLabel class="text-xs font-medium">
          {{ t('auth.signUp.birthDate') }}
        </FormLabel>
        <Popover>
          <PopoverTrigger as-child>
            <FormControl>
              <Button
                type="button"
                variant="outline"
                :class="
                  cn(
                    'h-9 w-full justify-start rounded-md text-left font-normal shadow-xs',
                    !value && 'text-muted-foreground'
                  )
                "
              >
                <CalendarIcon class="h-3.5 w-3.5" />
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
          <PopoverContent
            class="w-auto rounded-xl border-border/60 p-0"
            align="start"
          >
            <Calendar v-bind="componentField" initial-focus />
          </PopoverContent>
        </Popover>
        <Button v-if="value" type="button" variant="outline" class="w-fit" @click="handleChange(undefined)">
          {{ t('common.remove') }}
        </Button>
        <FormMessage class="text-[11px]" />
      </FormItem>
    </FormField>

    <FormField v-slot="{ componentField }" name="phone">
      <FormItem class="grid gap-2">
        <FormLabel class="text-xs font-medium">
          {{ t('account.profile.profilePage.phone') }}
        </FormLabel>
        <FormControl>
          <Input
            type="tel"
            autocomplete="tel"
            :placeholder="
              t(
                'account.profile.profilePage.phonePlaceholder'
              )
            "
            v-bind="componentField"
            class="h-9 shadow-xs"
          />
        </FormControl>
        <FormDescription class="text-[11px] text-muted-foreground">
          {{
            t('account.profile.profilePage.phoneDescription')
          }}
        </FormDescription>
        <FormMessage class="text-[11px]" />
      </FormItem>
    </FormField>

    <div class="flex flex-col gap-2 pt-1 sm:flex-row">
      <Button
        type="submit"
        :disabled="saving || !userInfo"
        class="h-9 w-full rounded-md shadow-xs sm:w-fit"
      >
        {{ t('account.profile.profilePage.updateProfile') }}
      </Button>

      <Button
        type="button"
        variant="outline"
        class="h-9 w-full rounded-md shadow-xs sm:w-fit"
        @click="resetForm"
      >
        {{ t('account.profile.profilePage.resetForm') }}
      </Button>
    </div>
  </form>
</template>
