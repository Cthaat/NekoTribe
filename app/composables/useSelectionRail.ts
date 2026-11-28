import { onMounted, onUpdated, ref, type CSSProperties } from 'vue'
import { useResizeObserver } from '@vueuse/core'

export function useSelectionRail(selector: string) {
  const list = ref<HTMLElement>()
  const style = ref<CSSProperties>()
  function measure() {
    const item = list.value?.querySelector<HTMLElement>(selector)
    const top = item?.offsetTop
    const height = item?.offsetHeight
    if (style.value?.['--rail-top'] === top && style.value?.['--rail-height'] === height) return
    style.value = item ? { '--rail-top': top, '--rail-height': height } : undefined
  }
  onMounted(measure)
  onUpdated(measure)
  useResizeObserver(list, measure)
  return { list, style }
}
