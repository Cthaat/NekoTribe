<script setup lang="ts">
import { useId } from 'vue';
import { ChartNoAxesColumn, Plus, Trash2 } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { newPostPollDraft, postPollLimits, postPollPayload, type PostPollDraft } from '@/utils/post-poll-draft';

defineProps<{ disabled?: boolean }>();
const draft = defineModel<PostPollDraft | null>({ required: true });
const { t } = useAppLocale();
const editorId = useId();
</script>

<template>
  <div class="space-y-3">
    <Button v-if="!draft" type="button" size="sm" variant="outline" :disabled="disabled" @click="draft = newPostPollDraft()">
      <ChartNoAxesColumn class="h-4 w-4" />{{ t('post.poll.add') }}
    </Button>
    <fieldset v-else :disabled="disabled" class="space-y-3 rounded-xl border border-border/80 bg-muted/20 p-3 sm:p-4">
      <legend class="px-1 text-sm font-semibold">{{ t('post.poll.title') }}</legend>
      <div v-for="(_, index) in draft.options" :key="index" class="flex items-center gap-2">
        <Input v-model="draft.options[index]" :id="`${editorId}-${index}`" maxlength="240"
          :aria-label="t('post.poll.option', {index:index+1})" :placeholder="t('post.poll.option', {index:index+1})" />
        <Button v-if="draft.options.length > postPollLimits.min" type="button" variant="ghost" size="icon"
          :aria-label="t('post.poll.removeOption')" @click="draft.options.splice(index,1)"><Trash2 class="h-4 w-4" /></Button>
      </div>
      <Button v-if="draft.options.length < postPollLimits.max" type="button" variant="outline" size="sm"
        @click="draft.options.push('')"><Plus class="h-4 w-4" />{{ t('post.poll.addOption') }}</Button>
      <div class="flex flex-wrap items-end gap-3 sm:gap-5">
        <label class="flex flex-1 flex-col gap-1 text-xs font-medium">
          {{ t('post.poll.cutoff') }}
          <Input v-model="draft.closesLocal" type="datetime-local" />
        </label>
        <label class="inline-flex min-h-9 items-center gap-2 text-sm">
          <input v-model="draft.multiple" type="checkbox" />{{ t('post.poll.multiple') }}
        </label>
      </div>
      <div class="flex flex-wrap items-center justify-between gap-2">
        <span v-if="!postPollPayload(draft)" class="text-xs text-muted-foreground">{{ t('post.poll.complete') }}</span>
        <Button type="button" variant="ghost" size="sm" class="text-muted-foreground" @click="draft = null">
          {{ t('post.poll.remove') }}
        </Button>
      </div>
    </fieldset>
  </div>
</template>
