import { ref, type Ref } from 'vue'

export function useSheetDrag(handle: Ref<HTMLElement | undefined>, dismiss: () => void) {
  const offset = ref(0)
  let pointer: number | undefined
  let origin = 0
  function start(event: PointerEvent) {
    if (!event.isPrimary || event.button !== 0 || !handle.value) return
    pointer = event.pointerId
    origin = event.clientY
    handle.value.setPointerCapture(pointer)
  }
  function move(event: PointerEvent) {
    if (event.pointerId === pointer) offset.value = Math.max(0, event.clientY - origin)
  }
  function cancel(event: PointerEvent) {
    if (event.pointerId !== pointer) return
    pointer = undefined
    offset.value = 0
  }
  function finish(event: PointerEvent) {
    if (event.pointerId !== pointer) return
    const distance = event.clientY - origin
    cancel(event)
    if (distance >= 64) dismiss()
  }
  return { offset, start, move, finish, cancel }
}
