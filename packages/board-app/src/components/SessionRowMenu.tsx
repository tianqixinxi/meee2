// Session row 的 hover overlay 菜单。Sidebar 每行原本暴露三个 inline 图标
// 按钮（pin / rename / canvas-eye），改成单个 ⋯ MoreHorizontal 按钮——hover
// 时显现，点开弹下面这个菜单。视觉参考用户给的截图 + Claude Code Desktop
// 自身的设计语言：item 名称在左，快捷键单字母在右，分隔线分组。
//
// 菜单项：
//   Open in ▸  (submenu: Canvas + 该 session 真正归属的 host —— 终端 / Claude.app /
//               Codex.app …)
//   Pin / Unpin                                                              [P]
//   Rename                                                                   [R]
//   Duplicate                                                                [D]
//
// 不在 PR 里：Archive / Delete / Mark as unread —— 后续单独实现。

import { useEffect, useRef, useState } from 'react'
import {
  ChevronRight,
  Pin,
  PinOff,
  Pencil,
  Copy,
  MonitorSmartphone,
  Layout as CanvasIcon,
  Terminal as TerminalIcon,
  AppWindow,
  EyeOff,
} from 'lucide-react'
import type { Session } from '../types'

export interface SessionRowMenuProps {
  session: Session
  isPinned: boolean
  /** 关闭菜单（点 backdrop / Esc / 选中某项后调用）。 */
  onClose: () => void
  /** "Open in → Canvas"：让该 session 在 board canvas 上显示并展开 transcript。 */
  onOpenInCanvas: () => void
  /** "Open in → 原始客户端"：CLI session 跳到 terminal，desktop session 切到 Claude.app。
   *  实际 dispatching 在父组件，这里只暴露 callback。 */
  onOpenInOriginal: () => void
  onTogglePin: () => void
  onRename: () => void
  onDuplicate: () => void
  /** "Hide from canvas"：把该 session sid 加进 dismissed 集合，下次刷新不再
   *  自动建卡片。仅在 session 已经在 canvas 上时才显示这一项 —— 不在的话
   *  Hide 无意义。父组件传 undefined 即不渲染该 menu item。 */
  onHide?: () => void
  /** 菜单挂在 session 行的 ⋯ 按钮上，传入按钮的 DOMRect 用来定位 overlay。 */
  anchorRect: DOMRect | null
}

/// 推断"原始客户端"的显示名 + 图标。
/// - clientKind === 'desktop' → "Claude Desktop" with AppWindow
/// - clientKind === 'cowork'  → "Claude Cowork" with AppWindow
/// - clientKind === 'cli' / null + termProgram → "<Terminal>" with Terminal
///   (Ghostty / iTerm / Terminal / Codex…)
/// - 不知道 → 通用 "Original client" with MonitorSmartphone
export function originalClientLabel(s: Session): string {
  if (s.clientKind === 'desktop') {
    if (s.pluginId.includes('codex')) return 'Codex Desktop'
    return 'Claude Desktop'
  }
  if (s.clientKind === 'cowork') return 'Claude Cowork'
  // CLI / unknown：根据 termProgram 文案
  const tp = (s.termProgram ?? '').toLowerCase()
  if (tp.includes('ghostty')) return 'Ghostty'
  if (tp.includes('iterm')) return 'iTerm'
  if (tp.includes('apple_terminal') || tp === 'terminal') return 'Terminal'
  if (tp) return tp
  return 'Original client'
}

function OriginalClientIcon({ session }: { session: Session }) {
  const props = { size: 13, 'aria-hidden': true } as const
  if (session.clientKind === 'desktop' || session.clientKind === 'cowork') {
    return <AppWindow {...props} />
  }
  return <TerminalIcon {...props} />
}

/// 菜单 item 视觉骨架：左 icon + label，右快捷键。disabled / danger 各自变体。
function MenuItem({
  icon,
  label,
  shortcut,
  onClick,
  hasSubmenu,
  danger,
  disabled,
  onMouseEnter,
}: {
  icon: React.ReactNode
  label: string
  shortcut?: string
  onClick?: () => void
  hasSubmenu?: boolean
  danger?: boolean
  disabled?: boolean
  onMouseEnter?: () => void
}) {
  return (
    <button
      type="button"
      className={
        'srm-item' +
        (danger ? ' srm-item--danger' : '') +
        (disabled ? ' srm-item--disabled' : '')
      }
      onClick={disabled ? undefined : onClick}
      onMouseEnter={onMouseEnter}
      disabled={disabled}
    >
      <span className="srm-item__icon" aria-hidden>{icon}</span>
      <span className="srm-item__label">{label}</span>
      {hasSubmenu && (
        <span className="srm-item__chevron" aria-hidden><ChevronRight size={12} /></span>
      )}
      {!hasSubmenu && shortcut && (
        <span className="srm-item__shortcut" aria-hidden>{shortcut}</span>
      )}
    </button>
  )
}

export function SessionRowMenu({
  session,
  isPinned,
  onClose,
  onOpenInCanvas,
  onOpenInOriginal,
  onTogglePin,
  onRename,
  onDuplicate,
  onHide,
  anchorRect,
}: SessionRowMenuProps) {
  const rootRef = useRef<HTMLDivElement | null>(null)
  const [submenuOpen, setSubmenuOpen] = useState(false)

  // 关闭逻辑：
  //   - 点击 backdrop（fixed inset:0 透明覆盖层）→ onClose
  //   - 按 Esc → onClose
  //   - 选中某个 item 时 item 自己 onClick 里调 onClose
  // 之前用 document.addEventListener('mousedown', ..., capture: true) 做
  // click-outside 检测，结果在某些 React 18 重渲染时序下会比 button 的
  // onClick 早一步把菜单 unmount —— 用户看到"点了没反应"。Backdrop pattern
  // 是 React 标准做法，不会跟 component-internal 事件竞争。
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        onClose()
        return
      }
      // 字母快捷键 P / R / D 不能在 input/textarea 里触发，否则用户重命名
      // 中敲 'p' 会被吞，CommandBar 打字也会被吞。
      const ae = document.activeElement as HTMLElement | null
      if (ae) {
        const tag = ae.tagName.toLowerCase()
        if (tag === 'input' || tag === 'textarea' || ae.isContentEditable) return
      }
      const k = e.key.toLowerCase()
      if (k === 'p') { e.preventDefault(); onTogglePin(); onClose() }
      else if (k === 'r') { e.preventDefault(); onRename(); onClose() }
      else if (k === 'd') { e.preventDefault(); onDuplicate(); onClose() }
      else if (k === 'h' && onHide) { e.preventDefault(); onHide(); onClose() }
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [onClose, onTogglePin, onRename, onDuplicate, onHide])

  // 默认贴在 anchor 右下；如果右侧出屏就翻转到左侧
  const style: React.CSSProperties = {}
  if (anchorRect) {
    const W = 220
    const margin = 4
    style.top = anchorRect.bottom + margin
    const wantLeft = anchorRect.right - W
    style.left = Math.max(8, wantLeft)
  }

  return (
    <>
      {/* Backdrop —— 占满 viewport 的透明层，捕获菜单外的任意点击关掉
       *  菜单。比 document-level capture listener 可靠。pointer-events
       *  按需打开（默认 transparent，不影响背后元素的 visual hover state）。 */}
      <div className="srm-backdrop" onClick={onClose} />
      <div ref={rootRef} className="srm-overlay" style={style} role="menu">
      {/* Open in ▸ 带 submenu */}
      <div
        className={'srm-item-wrap' + (submenuOpen ? ' is-submenu-open' : '')}
        onMouseEnter={() => setSubmenuOpen(true)}
        onMouseLeave={() => setSubmenuOpen(false)}
      >
        <MenuItem
          icon={<MonitorSmartphone size={13} aria-hidden />}
          label="Open in"
          hasSubmenu
        />
        {submenuOpen && (
          <div className="srm-submenu" role="menu">
            <MenuItem
              icon={<CanvasIcon size={13} aria-hidden />}
              label="Canvas"
              onClick={() => { onOpenInCanvas(); onClose() }}
            />
            <MenuItem
              icon={<OriginalClientIcon session={session} />}
              label={originalClientLabel(session)}
              onClick={() => { onOpenInOriginal(); onClose() }}
            />
          </div>
        )}
      </div>

      <div className="srm-divider" aria-hidden />

      <MenuItem
        icon={isPinned
          ? <PinOff size={13} aria-hidden />
          : <Pin size={13} aria-hidden />}
        label={isPinned ? 'Unpin' : 'Pin'}
        shortcut="P"
        onClick={() => { onTogglePin(); onClose() }}
      />
      <MenuItem
        icon={<Pencil size={13} aria-hidden />}
        label="Rename"
        shortcut="R"
        onClick={() => { onRename(); onClose() }}
      />
      <MenuItem
        icon={<Copy size={13} aria-hidden />}
        label="Duplicate"
        shortcut="D"
        onClick={() => { onDuplicate(); onClose() }}
      />
      {onHide && (
        <>
          <div className="srm-divider" aria-hidden />
          <MenuItem
            icon={<EyeOff size={13} aria-hidden />}
            label="Hide from canvas"
            shortcut="H"
            onClick={() => { onHide(); onClose() }}
          />
        </>
      )}
      </div>
    </>
  )
}
