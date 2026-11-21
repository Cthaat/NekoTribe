<script setup lang="ts">
import type { AiAvailabilityState, AiSkillSummary } from '@/services/ai-writing-controller';

defineProps<{ availability: AiAvailabilityState; skill?: AiSkillSummary; modelConfigRevision?: number }>();
const { t } = useAppLocale();
</script>

<template>
  <p role="status" class="text-sm text-muted-foreground">
    <span v-if="skill" class="mr-2 font-medium">
      {{ t('aiAvailability.skillVersion', { name: t(`aiAvailability.skillNames.${skill.id}`), version: skill.version }) }}
    </span>
    {{ t(`aiAvailability.${availability}`) }}
    <span v-if="modelConfigRevision !== undefined" class="mt-1 block">
      {{ t('aiAvailability.modelConfigRevision', { revision: modelConfigRevision }) }}
    </span>
  </p>
</template>
