import { useCallback, useEffect, useRef, useState } from 'react'
import { guideEffectDuration, type BoardGuideTarget } from '../lib/guide'

interface ActiveGuide {
  target: BoardGuideTarget
  rect: DOMRectReadOnly
}

export function GuideOverlay() {
  const [active, setActive] = useState<ActiveGuide | null>(null)
  const activeRef = useRef<ActiveGuide | null>(null)
  const clearTimerRef = useRef<number | null>(null)
  const frameRef = useRef<number | null>(null)

  const clearGuide = useCallback(() => {
    if (clearTimerRef.current !== null) {
      window.clearTimeout(clearTimerRef.current)
      clearTimerRef.current = null
    }
    if (frameRef.current !== null) {
      window.cancelAnimationFrame(frameRef.current)
      frameRef.current = null
    }
    activeRef.current = null
    setActive(null)
  }, [])

  const resolveTargetRect = useCallback((target: BoardGuideTarget): DOMRectReadOnly | null => {
    if (target.kind === 'rect') {
      return new DOMRect(target.rect.x, target.rect.y, target.rect.width, target.rect.height)
    }
    if (target.kind !== 'selector') return null
    const element = document.querySelector(target.selector)
    if (!(element instanceof HTMLElement || element instanceof SVGElement)) return null
    const rect = element.getBoundingClientRect()
    if (rect.width <= 0 || rect.height <= 0) return null
    return rect
  }, [])

  const showTarget = useCallback((target: BoardGuideTarget) => {
    clearGuide()
    const startedAt = performance.now()
    const tryResolve = () => {
      const rect = resolveTargetRect(target)
      if (rect) {
        const next = { target, rect }
        activeRef.current = next
        setActive(next)
        clearTimerRef.current = window.setTimeout(clearGuide, guideEffectDuration(target.durationMs))
        return
      }
      if (performance.now() - startedAt > 1800) return
      frameRef.current = window.requestAnimationFrame(tryResolve)
    }
    tryResolve()
  }, [clearGuide, resolveTargetRect])

  useEffect(() => {
    const onGuide = (event: Event) => {
      const target = (event as CustomEvent<BoardGuideTarget>).detail
      if (!target || target.kind === 'planner-node') return
      showTarget(target)
    }
    window.addEventListener('meee2:guide-target', onGuide)
    return () => window.removeEventListener('meee2:guide-target', onGuide)
  }, [showTarget])

  useEffect(() => {
    if (!active) return undefined
    const updateRect = () => {
      const current = activeRef.current
      if (!current) return
      const rect = resolveTargetRect(current.target)
      if (!rect) return
      const next = { ...current, rect }
      activeRef.current = next
      setActive(next)
    }
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') clearGuide()
    }
    window.addEventListener('resize', updateRect)
    window.addEventListener('scroll', updateRect, true)
    window.addEventListener('keydown', onKeyDown)
    return () => {
      window.removeEventListener('resize', updateRect)
      window.removeEventListener('scroll', updateRect, true)
      window.removeEventListener('keydown', onKeyDown)
    }
  }, [active, clearGuide, resolveTargetRect])

  useEffect(() => clearGuide, [clearGuide])

  if (!active) return null

  const { rect } = active
  const pad = 10
  const left = Math.max(8, rect.left - pad)
  const top = Math.max(8, rect.top - pad)
  const width = Math.min(window.innerWidth - left - 8, rect.width + pad * 2)
  const height = Math.min(window.innerHeight - top - 8, rect.height + pad * 2)

  return (
    <div
      className="guide-overlay"
      aria-hidden="true"
      onPointerDown={clearGuide}
    >
      <div
        className="guide-overlay__ring"
        style={{ left, top, width, height }}
      />
    </div>
  )
}
