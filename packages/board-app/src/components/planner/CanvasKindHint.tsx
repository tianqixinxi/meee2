import { useEffect, useState } from 'react'
import { Info, X } from 'lucide-react'
import type { CanvasKind } from '../../types'

/**
 * UI-simplification chunk G — 顶部 hint 条
 *
 * 仅 monitor canvas 显示。kanban / inbox / matrix 不是 canvas kind 而是 node-
 * level widget(2026-05-28 心智修正),它们的 hint 走 widget renderer 自带的
 * tooltip,不再走这里。
 */

type HintKind = 'monitor'

const HINT_COPY: Record<HintKind, { title: string; body: string }> = {
  monitor: {
    title: '监控台',
    body: '聚合所有 canvas 的健康度,点节点下钻。',
  },
}

function dismissKey(kind: HintKind): string {
  return `meee2.canvas-hint-dismissed.${kind}.v1`
}

interface Props {
  kind: CanvasKind | HintKind
}

export function CanvasKindHint({ kind }: Props) {
  // 只 monitor 有 hint。其他 kind 不显示。
  const hintKind: HintKind | null = kind === 'monitor' ? 'monitor' : null

  const [dismissed, setDismissed] = useState<boolean>(() => {
    if (!hintKind) return true
    try {
      return localStorage.getItem(dismissKey(hintKind)) === '1'
    } catch {
      return false
    }
  })

  // Reset dismissed-state when the kind changes (e.g. user navigated to a
  // different canvas kind that has its own dismissal flag).
  useEffect(() => {
    if (!hintKind) {
      setDismissed(true)
      return
    }
    try {
      setDismissed(localStorage.getItem(dismissKey(hintKind)) === '1')
    } catch {
      setDismissed(false)
    }
  }, [hintKind])

  if (!hintKind || dismissed) return null

  const copy = HINT_COPY[hintKind]

  const dismiss = () => {
    try {
      localStorage.setItem(dismissKey(hintKind), '1')
    } catch {
      // ignore (private mode / disk full); state toggle below still hides for this session
    }
    setDismissed(true)
  }

  return (
    <div className={`canvas-kind-hint canvas-kind-hint--${hintKind}`} role="note">
      <Info size={13} aria-hidden className="canvas-kind-hint__icon" />
      <span className="canvas-kind-hint__copy">
        <strong>{copy.title}</strong>
        <span className="canvas-kind-hint__sep">·</span>
        <span>{copy.body}</span>
      </span>
      <button
        type="button"
        className="canvas-kind-hint__dismiss"
        onClick={dismiss}
        aria-label={`关闭 ${copy.title} 提示`}
      >
        <X size={12} aria-hidden />
      </button>
    </div>
  )
}
