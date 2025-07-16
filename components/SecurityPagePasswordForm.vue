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

const { t } = useI18n();

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

const { handleSubmit, resetForm } = useForm({
  validationSchema: profileFormSchema,
  initialValues: {}
});

const onSubmit = handleSubmit(async values => {});
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

    <div class="flex gap-2 justify-start">
      <Button type="submit"> Update profile </Button>
    </div>
  </form>
</template>
