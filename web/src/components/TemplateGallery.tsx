// 卡片模板预览网格：把 TemplateEditor 底下那排文字按钮升级成
// "活渲染缩略图" —— 每个 tile 是用 stub session data 实时 compile + render
// 出来的真模板，扫一眼就知道每个 preset 长什么样。
//
// 实现要点：
//  - 每个 tile 内嵌 CardHost，喂同一份 fake session，用 CSS transform:scale
//    把它缩到 tile 尺寸；缩放基于真实 360×260 → 240×160
//  - CardHost 自带 Error Boundary，preset TSX 出错也只影响该 tile
//  - Selected 态用 accent 边框 + 左上 "in use" 徽标
//  - Grid responsive: 容器 < 520px 单列，≥ 520px 双列

import { memo, useMemo } from 'react'
import { CardHost } from './CardHost'
import type { Session, BoardState } from '../types'

// 缩略图尺寸（显示尺寸），和真实 card 的 360×260 等比
const THUMB_W = 240
const THUMB_H = 160
const REAL_W = 360
const REAL_H = 260
const SCALE = THUMB_W / REAL_W

/**
 * 一个足够 "饱满" 的 fake session —— 带 status=tooling（活跃）、
 * currentTool、recentMessages、usageStats，让所有 preset 都能展示出最多
 * 信息。如果用 idle / 空消息，minimal / stats 这些 preset 会空一大片。
 */
const FAKE_SESSION: Session = {
  id: 'preview-00000000',
  title: 'meee2',
  project: '/Users/qc/projects/meee1_code/meee2',
  pluginId: 'com.meee2.plugin.claude',
  pluginDisplayName: 'Claude Code',
  pluginColor: '#FF9230',
  status: 'tooling',
  inboxPending: 0,
  recentMessages: [
    { role: 'user', text: '把这个 bug 修一下' },
    { role: 'assistant', text: '看了一眼，是 AppleScript focus 的问题——Ghostty 的 focus 命令只抬窗口不切 tab。' },
    { role: 'tool', text: '🔧 Read: TerminalJumper.swift' },
    { role: 'tool', text: '🔧 Edit: TerminalJumper.swift' },
    { role: 'assistant', text: '改完了。加了 windows→tabs→terminals 的层级遍历，先 select tab 再 focus。' },
  ],
  currentTool: 'Bash',
  costUSD: 2.14,
  pendingPermissionTool: null,
  pendingPermissionMessage: null,
  startedAt: new Date(Date.now() - 1800_000).toISOString(),
  lastActivity: new Date().toISOString(),
  usageStats: {
    turns: 42,
    inputTokens: 8123,
    outputTokens: 34210,
    cacheCreateTokens: 128400,
    cacheReadTokens: 2_840_000,
    model: 'claude-opus-4-7',
  },
  tasks: [],
  ghosttyTerminalId: null,
  tty: null,
  termProgram: 'ghostty',
  backgroundAgents: [],
  latestRecap: null,
} as unknown as Session

const FAKE_BOARD: BoardState = {
  sessions: [FAKE_SESSION],
  channels: [],
} as unknown as BoardState

interface TemplateGalleryProps {
  presets: Array<{
    id: string
    label: string
    description: string
    source: string
  }>
  /** 当前选中的 preset id（或 null 表示都没选） */
  selectedId: string | null
  onSelect: (preset: { id: string; label: string; description: string; source: string }) => void
  /** 点击 "+" tile 时触发，宿主应该打开 custom-card modal */
  onRequestCustom?: () => void
}

export function TemplateGallery({ presets, selectedId, onSelect, onRequestCustom }: TemplateGalleryProps) {
  return (
    <div className="tpl-gallery">
      {presets.map((preset) => (
        <TemplateTile
          key={preset.id}
          preset={preset}
          selected={preset.id === selectedId}
          onClick={() => onSelect(preset)}
        />
      ))}
      {onRequestCustom && <AddTile onClick={onRequestCustom} />}
    </div>
  )
}

function AddTile({ onClick }: { onClick: () => void }) {
  return (
    <button
      type="button"
      className="tpl-tile tpl-tile--add"
      onClick={onClick}
      title="Create a custom card from your own TSX"
    >
      <div className="tpl-tile__preview tpl-tile__preview--add">
        <span className="tpl-tile__plus" aria-hidden>+</span>
      </div>
      <div className="tpl-tile__meta">
        <span className="tpl-tile__label">Custom</span>
        <span className="tpl-tile__desc">Paste your own TSX or ask Claude Code to generate one</span>
      </div>
    </button>
  )
}

// memo 让只有 preset.source / selected 变化时才 re-render 该 tile（否则父
// 组件每次 re-render 都要 5 次 Babel compile + render，非常贵）
const TemplateTile = memo(function TemplateTile({
  preset,
  selected,
  onClick,
}: {
  preset: { id: string; label: string; description: string; source: string }
  selected: boolean
  onClick: () => void
}) {
  // source 也 memoize —— CardHost 内部已经 useMemo 过 compileCardSource，这里
  // 纯防御：source 是一整段 kB 级别字符串，值相等时直接 pass 下去
  const source = useMemo(() => preset.source, [preset.source])

  return (
    <button
      type="button"
      className={`tpl-tile${selected ? ' tpl-tile--selected' : ''}`}
      onClick={onClick}
      title={preset.description}
    >
      <div className="tpl-tile__preview">
        <div
          className="tpl-tile__preview-scale"
          style={{
            width: REAL_W,
            height: REAL_H,
            transform: `scale(${SCALE})`,
            transformOrigin: 'top left',
          }}
        >
          <CardHost
            sessionId={FAKE_SESSION.id}
            session={FAKE_SESSION}
            board={FAKE_BOARD}
            source={source}
          />
        </div>
        {selected && (
          <span className="tpl-tile__badge" aria-label="in use">
            ● in use
          </span>
        )}
      </div>
      <div className="tpl-tile__meta">
        <span className="tpl-tile__label">{preset.label}</span>
        <span className="tpl-tile__desc">{preset.description}</span>
      </div>
    </button>
  )
})
