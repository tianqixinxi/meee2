// Custom Card 创建模态框。从 TemplateGallery 的 "+" tile 打开。
//
// 用户流程：
//   1. 看到一段可复制的 Claude Code instruction，把它贴进他的 Claude CLI 让
//      Claude 帮他写一份 TSX（session 数据形状 + 渲染约束都写清楚）
//   2. 把 Claude 吐出的 TSX 贴回 textarea
//   3. 起个名字、写个一句话描述
//   4. 点 Save —— compile 通过 → 加进 user preset 库 →  gallery 立即出现
//
// 本模态框不做"apply 到当前 session"，那个动作在 gallery 的 onSelect 里做：
// 保存后 gallery 自动 re-render 并把新 preset 暴露出来，用户再点那个 tile
// 就会 apply。拆开两步是为了"库"和"应用"心智模型分开。

import { useEffect, useMemo, useRef, useState } from 'react'
import { compileCardSource } from '../cardCompile'
import { addUserPreset, userPresetIdFromLabel } from '../userPresets'
import type { TemplatePreset } from '../templatePresets'

// 贴给 Claude Code 的 instruction：既告诉数据形状（session / board /
// helpers），也给出 runtime 约束（no imports, 360×260, 自包含），再给一个
// 风格 placeholder。用户把这段贴进自己的 Claude CLI，说"照这个写一个 XX 风
// 格的 card"，Claude 会吐出一段能直接复制回 textarea 的 TSX。
const CLAUDE_INSTRUCTION = `请帮我写一个 meee2 card template。这是一段 TSX，会通过 Babel standalone
在浏览器端动态编译运行。

硬约束：
  • 必须 \`export default\` 一个 React function component
  • 不能有 import —— 所有 helper 函数内联
  • 运行时全局只有 React（通过 React.createElement，JSX 走 classic runtime）
  • 渲染区域固定 360×260 px（外层 div 必须 width: '100%', height: '100%'）
  • 禁止副作用（不能访问 parent DOM / window 以外的东西）

收到的 props：{ session, board, helpers }

session 的字段形状：
  id              string                UUID
  title           string                窗口标题（常是 project 名）
  project         string                cwd
  pluginId        string                如 "com.meee2.plugin.claude"
  pluginDisplayName string              如 "Claude Code"
  pluginColor     string                hex like "#FF9230"
  status          string                idle/thinking/tooling/active/
                                        waitingForUser/permissionRequired/
                                        compacting/completed/dead
  currentTool     string | null         如 "Bash"
  costUSD         number | null         累计成本
  inboxPending    number                A2A 待处理消息数
  recentMessages  Array<{role, text}>   role: user | assistant | tool
  usageStats      { turns, inputTokens, outputTokens, cacheCreateTokens,
                    cacheReadTokens, model }
  _animations     { liveHalo?: { color, speedSeconds, glowPx, intensity },
                    statusDotPulse?, arrivalFadeIn? }   可选 —— 用户定制的
                                        动效 override，建议读 session._animations
                                        然后 fallback 到硬编码默认值

我想要的风格：<在这里描述你想要的视觉语言，例如 "Monokai 代码编辑器风、等宽
字体、顶部 tab bar 显示 session 名、主体区按 lineno 列出最近工具调用"，或
"日式极简，大量留白，手写风英文字体，只有 hover 时露出数据">`

interface Props {
  onClose: () => void
  /** 保存成功时 → 父把新 preset 插进 gallery。返回新 preset 让外层高亮它 */
  onSaved: (preset: TemplatePreset) => void
}

export function CustomCardModal({ onClose, onSaved }: Props) {
  const [source, setSource] = useState('')
  const [label, setLabel] = useState('')
  const [desc, setDesc] = useState('')
  const [copied, setCopied] = useState(false)
  const firstInputRef = useRef<HTMLTextAreaElement | null>(null)

  const compileError = useMemo(() => {
    if (!source.trim()) return null
    return compileCardSource(source).error ?? null
  }, [source])

  // ESC 关闭
  useEffect(() => {
    const h = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', h)
    return () => window.removeEventListener('keydown', h)
  }, [onClose])

  // 挂载时 focus 到 label 输入 —— 用户最可能先想名字
  useEffect(() => { firstInputRef.current?.focus() }, [])

  const canSave =
    source.trim().length > 0 &&
    label.trim().length > 0 &&
    compileError == null

  const save = () => {
    if (!canSave) return
    const preset: TemplatePreset = {
      id: userPresetIdFromLabel(label),
      label: label.trim(),
      description: desc.trim() || 'Custom card',
      source,
    }
    addUserPreset(preset)
    onSaved(preset)
    onClose()
  }

  const copyInstruction = async () => {
    try {
      await navigator.clipboard.writeText(CLAUDE_INSTRUCTION)
      setCopied(true)
      window.setTimeout(() => setCopied(false), 1500)
    } catch {
      // 兜底：选中 → 让用户手动 Cmd+C
      const el = document.getElementById('card-custom-instruction-pre')
      if (el) {
        const range = document.createRange()
        range.selectNodeContents(el)
        const sel = window.getSelection()
        sel?.removeAllRanges()
        sel?.addRange(range)
      }
    }
  }

  return (
    <div className="card-custom-modal-backdrop" onClick={onClose}>
      <div className="card-custom-modal" onClick={(e) => e.stopPropagation()}>
        <div className="card-custom-modal__header">
          <div className="card-custom-modal__title">New custom card</div>
          <button onClick={onClose} title="Close (Esc)">✕</button>
        </div>

        <div className="card-custom-modal__body">
          {/* Step 1 —— Claude Code instruction */}
          <div>
            <div className="card-custom-modal__section-label">
              1. Ask Claude Code to write it (copy + paste this prompt)
            </div>
            <div className="card-custom-modal__prompt">
              <button
                className="card-custom-modal__copy-btn"
                onClick={copyInstruction}
                title="Copy instruction to clipboard"
              >
                {copied ? '✓ copied' : '📋 copy'}
              </button>
              <pre id="card-custom-instruction-pre" style={{ margin: 0, fontFamily: 'inherit', whiteSpace: 'pre-wrap' }}>
                {CLAUDE_INSTRUCTION}
              </pre>
            </div>
          </div>

          {/* Step 2 —— paste TSX back */}
          <div>
            <div className="card-custom-modal__section-label">
              2. Paste the TSX Claude wrote here
            </div>
            <textarea
              ref={firstInputRef}
              className="card-custom-modal__textarea"
              value={source}
              onChange={(e) => setSource(e.target.value)}
              spellCheck={false}
              placeholder="export default function MyCard({ session, board, helpers }) {&#10;  return (&#10;    <div style={{ ... }}>&#10;      ...&#10;    </div>&#10;  )&#10;}"
            />
            {compileError && (
              <div className="card-custom-modal__error" style={{ marginTop: 6 }}>
                {compileError}
              </div>
            )}
          </div>

          {/* Step 3 —— naming */}
          <div>
            <div className="card-custom-modal__section-label">
              3. Name it so you can reuse it
            </div>
            <div style={{ display: 'flex', gap: 8, marginTop: 4 }}>
              <input
                className="card-custom-modal__name-input"
                value={label}
                onChange={(e) => setLabel(e.target.value)}
                placeholder="e.g. Monokai, Retro terminal, Zen"
                maxLength={40}
              />
            </div>
            <input
              className="card-custom-modal__name-input"
              style={{ marginTop: 6 }}
              value={desc}
              onChange={(e) => setDesc(e.target.value)}
              placeholder="One-line description (optional)"
              maxLength={120}
            />
          </div>
        </div>

        <div className="card-custom-modal__footer">
          <button onClick={onClose}>Cancel</button>
          <button
            className="primary"
            onClick={save}
            disabled={!canSave}
            title={
              !source.trim() ? 'Paste some TSX first'
                : !label.trim() ? 'Give it a name'
                : compileError ? 'Fix the compile error first'
                : 'Save to your preset library'
            }
          >
            Save to library
          </button>
        </div>
      </div>
    </div>
  )
}
