// 通用 hover tooltip：黑色圆角气泡 + 可选 shortcut pill。
//
//   <Tooltip label="Toggle sidebar" shortcut="⌘B">
//     <button>...</button>
//   </Tooltip>
//
// 实现要点：
// 1. 用 portal 挂到 document.body，绕开 sidebar / dock 的 overflow: hidden 裁剪。
// 2. cloneElement 注入 onMouseEnter/Leave/Focus/Blur，callsite 不需要改 props。
// 3. 默认 ~400ms 延时（VSCode 风格），避免鼠标划过时闪。
// 4. 多个 tooltip 之间有 50ms grace 期：用户从 A 滑到 B 时，B 立刻显示
//    （没有重新等 400ms），跟 macOS toolbar / Linear 体验对齐。

import {
  cloneElement,
  isValidElement,
  useCallback,
  useEffect,
  useRef,
  useState,
} from 'react'
import { createPortal } from 'react-dom'

interface TooltipProps {
  label: string
  /** 可选键盘快捷键，渲染成右侧小 pill（如 "⌘B" / "Esc" / "P"）。 */
  shortcut?: string
  /** 默认 'bottom'。视口边缘自动 fallback 到可见方向。 */
  placement?: 'top' | 'bottom' | 'left' | 'right'
  /** Hover 多久后显示，毫秒。默认 400。 */
  delay?: number
  /** 传 false 临时禁用（比如 disabled state 下不弹）。 */
  enabled?: boolean
  children: React.ReactElement
}

// 全局 grace 计时：上一个 tooltip 关闭后 GRACE_MS 内,新 tooltip 跳过 delay。
const GRACE_MS = 80
let lastClosedAt = 0

export function Tooltip({
  label,
  shortcut,
  placement = 'bottom',
  delay = 400,
  enabled = true,
  children,
}: TooltipProps) {
  const [open, setOpen] = useState(false)
  const [resolvedPlacement, setResolvedPlacement] = useState<'top' | 'bottom' | 'left' | 'right'>(placement)
  const [pos, setPos] = useState<{ top: number; left: number } | null>(null)
  const timerRef = useRef<number | null>(null)
  const anchorRef = useRef<HTMLElement | null>(null)
  const bubbleRef = useRef<HTMLDivElement | null>(null)

  const computePosition = useCallback(() => {
    const el = anchorRef.current
    if (!el) return
    const r = el.getBoundingClientRect()
    const margin = 8
    const cx = r.left + r.width / 2
    const cy = r.top + r.height / 2
    const vw = window.innerWidth
    const vh = window.innerHeight
    // 默认按 placement，但超出视口边缘时翻转
    let p: 'top' | 'bottom' | 'left' | 'right' = placement
    if (placement === 'bottom' && r.bottom + 56 > vh) p = 'top'
    if (placement === 'top' && r.top - 56 < 0) p = 'bottom'
    if (placement === 'right' && r.right + 180 > vw) p = 'left'
    if (placement === 'left' && r.left - 180 < 0) p = 'right'
    const top = p === 'top'
      ? r.top - margin
      : p === 'bottom'
        ? r.bottom + margin
        : cy
    const left = p === 'right'
      ? r.right + margin
      : p === 'left'
        ? r.left - margin
        : cx
    setResolvedPlacement(p)
    setPos({ top, left })
  }, [placement])

  const show = useCallback(() => {
    if (!enabled) return
    if (timerRef.current) {
      window.clearTimeout(timerRef.current)
      timerRef.current = null
    }
    const fast = Date.now() - lastClosedAt < GRACE_MS
    const wait = fast ? 0 : delay
    timerRef.current = window.setTimeout(() => {
      computePosition()
      setOpen(true)
      timerRef.current = null
    }, wait)
  }, [enabled, computePosition, delay])

  const hide = useCallback(() => {
    if (timerRef.current) {
      window.clearTimeout(timerRef.current)
      timerRef.current = null
    }
    setOpen((prev) => {
      if (prev) lastClosedAt = Date.now()
      return false
    })
  }, [])

  // unmount 清理 timer
  useEffect(() => () => {
    if (timerRef.current) window.clearTimeout(timerRef.current)
  }, [])

  // 打开时跟随 scroll / resize 重新定位（fixed 定位本身不会跟随 scroll）
  useEffect(() => {
    if (!open) return
    const onMove = () => computePosition()
    window.addEventListener('scroll', onMove, true)
    window.addEventListener('resize', onMove)
    return () => {
      window.removeEventListener('scroll', onMove, true)
      window.removeEventListener('resize', onMove)
    }
  }, [open, computePosition])

  if (!isValidElement(children)) return children as React.ReactNode

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const childAny = children as any
  const childProps = childAny.props ?? {}

  const cloned = cloneElement(childAny, {
    ref: (node: HTMLElement | null) => {
      anchorRef.current = node
      // 转发原本的 ref（function ref / object ref / React 19 ref-as-prop 全兼容）
      const incomingRef = childAny.ref ?? childProps.ref
      if (typeof incomingRef === 'function') incomingRef(node)
      else if (incomingRef && typeof incomingRef === 'object') incomingRef.current = node
    },
    onMouseEnter: (e: React.MouseEvent) => {
      childProps.onMouseEnter?.(e)
      show()
    },
    onMouseLeave: (e: React.MouseEvent) => {
      childProps.onMouseLeave?.(e)
      hide()
    },
    onFocus: (e: React.FocusEvent) => {
      childProps.onFocus?.(e)
      // 只有键盘 focus 才显示，鼠标点击 focus 不弹（用 :focus-visible 的近似）
      const t = e.target as HTMLElement
      if (t.matches?.(':focus-visible')) show()
    },
    onBlur: (e: React.FocusEvent) => {
      childProps.onBlur?.(e)
      hide()
    },
    onClick: (e: React.MouseEvent) => {
      childProps.onClick?.(e)
      // 点击后 tooltip 应该立刻消失（按钮按下了，文字提示没意义了）
      hide()
    },
  })

  return (
    <>
      {cloned}
      {open && pos && createPortal(
        <div
          ref={bubbleRef}
          className={'mee-tooltip mee-tooltip--' + resolvedPlacement}
          style={{ top: pos.top, left: pos.left }}
          role="tooltip"
        >
          <span className="mee-tooltip__label">{label}</span>
          {shortcut && <span className="mee-tooltip__shortcut">{shortcut}</span>}
        </div>,
        document.body,
      )}
    </>
  )
}
