import { onMounted, onScopeDispose } from 'vue'

export function useGlassGlint() {
  let stop: (() => void) | undefined
  onMounted(() => {
    const allowed = matchMedia('(hover: hover) and (pointer: fine) and (prefers-reduced-motion: no-preference) and (prefers-reduced-transparency: no-preference)')
    let surface: HTMLElement | null = null
    let frame = 0
    let x = 0
    let y = 0
    function clear() {
      cancelAnimationFrame(frame)
      frame = 0
      if (surface) delete surface.dataset.glint
      surface = null
    }
    function move(event: PointerEvent) {
      const target = event.pointerType !== 'touch' && event.target instanceof Element
        ? event.target.closest<HTMLElement>('.liquid-glass-button, .liquid-glass-island, .glass-command')
        : null
      if (target !== surface) clear()
      surface = target
      if (!surface) return
      x = event.clientX
      y = event.clientY
      if (frame) return
      frame = requestAnimationFrame(() => {
        frame = 0
        if (!surface) return
        const bounds = surface.getBoundingClientRect()
        surface.style.setProperty('--glint-x', (x - bounds.left) + 'px')
        surface.style.setProperty('--glint-y', (y - bounds.top) + 'px')
        surface.dataset.glint = ''
      })
    }
    function configure() {
      clear()
      document.removeEventListener('pointermove', move)
      if (allowed.matches) document.addEventListener('pointermove', move, { passive: true })
    }
    configure()
    allowed.addEventListener('change', configure)
    document.addEventListener('pointerleave', clear)
    stop = () => {
      clear()
      allowed.removeEventListener('change', configure)
      document.removeEventListener('pointermove', move)
      document.removeEventListener('pointerleave', clear)
    }
  })
  onScopeDispose(() => stop?.())
}
