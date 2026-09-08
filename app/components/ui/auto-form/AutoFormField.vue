<script setup lang="ts" generic="U extends ZodAny">
import type { ZodAny } from 'zod/v3'
import type { Config, ConfigItem, Shape } from './interface'
import { computed } from 'vue'
import { DEFAULT_ZOD_HANDLERS, INPUT_COMPONENTS } from './constant'
import useDependencies from './dependencies'

const props = defineProps<{
  fieldName: string
  shape: Shape
  config?: ConfigItem | Config<U>
}>()

function isValidConfig(config: unknown): config is ConfigItem {
  return (
    typeof config === 'object' &&
    config !== null &&
    'component' in config &&
    !!(config as ConfigItem).component
  )
}

const delegatedProps = computed(() => {
  if (['ZodObject', 'ZodArray'].includes(props.shape?.type))
    return { schema: props.shape?.schema }
  return undefined
})

const defaultComponent = computed(() => {
  const handler = DEFAULT_ZOD_HANDLERS[props.shape.type]
  return handler ? INPUT_COMPONENTS[handler] : undefined
})

const { isDisabled, isHidden, isRequired, overrideOptions } = useDependencies(props.fieldName)
</script>

<template>
  <component
    :is="isValidConfig(config)
      ? typeof config.component === 'string'
        ? INPUT_COMPONENTS[config.component!]
        : config.component
      : defaultComponent "
    v-if="!isHidden"
    :field-name="fieldName"
    :label="shape.schema?.description"
    :required="isRequired || shape.required"
    :options="overrideOptions || shape.options"
    :disabled="isDisabled"
    :config="config"
    v-bind="delegatedProps"
  >
    <slot />
  </component>
</template>
