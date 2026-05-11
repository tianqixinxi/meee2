import type { Session } from '../types'
import { Tooltip } from './Tooltip'

/**
 * Sidebar 顶部"导航区"——三段：
 *
 *   ┌─────────────────────────────┐
 *   │  [Tab]  [Tab]  [Tab]   ←tabs (可配置 plugin 分类胶囊)
 *   ├─────────────────────────────┤
 *   │  Search / Routines / Customize / More
 *   │  📦 Customize
 *   │  ▾ More
 *   └─────────────────────────────┘
 *
 * tabs 可配置：父组件传一个 `tabs` 数组，每个 tab 自带 predicate（match 哪些
 * session）。默认 tabs 从 board state 的 plugin 列表自动生成；调用方（meee2
 * 等）可以覆盖成"按归属人"等自定义维度。
 */

export interface SidebarTab {
  id: string
  label: string
  /** 可选 SVG icon 节点 */
  icon?: React.ReactNode
  /** 这个 tab 包含哪些 session；不传 → 所有 session */
  match?: (s: Session) => boolean
}

interface Props {
  tabs: SidebarTab[]
  activeTabId: string
  onTabChange: (id: string) => void
  /** Search action —— toggle 一个 inline 搜索 input（父组件管 visibility + query state） */
  onToggleSearch?: () => void
  onRoutines?: () => void
  onCustomize?: () => void
  onMore?: () => void
}

export function SidebarTopNav({
  tabs,
  activeTabId,
  onTabChange,
  onToggleSearch,
  onRoutines,
  onCustomize,
  onMore,
}: Props) {
  return (
    <div className="sidebar-topnav">
      {/* ── Tabs (plugin 分类胶囊) ───────────────────────────────────
       *  只有一个 tab 时直接不渲染整条 —— "All" 单独存在没意义，徒占
       *  垂直空间。≥2 个 tab 才展示。 */}
      {tabs.length > 1 && (
        <div className="stn-tabs" role="tablist">
          {tabs.map((t) => {
            const active = t.id === activeTabId
            return (
              <button
                key={t.id}
                className={'stn-tab' + (active ? ' stn-tab--active' : '')}
                role="tab"
                aria-selected={active}
                onClick={() => onTabChange(t.id)}
              >
                {t.icon && <span className="stn-tab-icon" aria-hidden>{t.icon}</span>}
                <span>{t.label}</span>
              </button>
            )
          })}
        </div>
      )}

      {/* ── Action items ────────────────────────────────────────── */}
      <div className="stn-actions">
        {onToggleSearch && (
          <Tooltip label="Search sessions (filter by title / project)">
            <button className="stn-action" onClick={onToggleSearch}>
              <span className="stn-action-icon" aria-hidden>
                {/* Lucide `search` —— 11,11 圆心 + 8 半径，对角 m21 21-4.3 是把柄 */}
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none"
                     stroke="currentColor" strokeWidth="2"
                     strokeLinecap="round" strokeLinejoin="round">
                  <circle cx="11" cy="11" r="8"/>
                  <path d="m21 21-4.3-4.3"/>
                </svg>
              </span>
              Search
            </button>
          </Tooltip>
        )}
        {onRoutines && (
          <Tooltip label="Routines (scheduled background tasks)">
            <button className="stn-action" onClick={onRoutines}>
              <span className="stn-action-icon" aria-hidden>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                  <path d="M13 2L4 14h7l-1 8 9-12h-7l1-8z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" fill="none"/>
                </svg>
              </span>
              Routines
            </button>
          </Tooltip>
        )}
        {onCustomize && (
          <Tooltip label="Customize">
            <button className="stn-action" onClick={onCustomize}>
              <span className="stn-action-icon" aria-hidden>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                  <rect x="3" y="7" width="18" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/>
                  <path d="M8 7V5a4 4 0 0 1 8 0v2" stroke="currentColor" strokeWidth="1.8"/>
                </svg>
              </span>
              Customize
            </button>
          </Tooltip>
        )}
        {onMore && (
          <Tooltip label="More">
            <button className="stn-action" onClick={onMore}>
              <span className="stn-action-icon" aria-hidden>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                  <path d="M6 9l6 6 6-6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
              </span>
              More
            </button>
          </Tooltip>
        )}
      </div>
    </div>
  )
}

/// 默认从 board state 的 plugin 列表自动生成 tabs：
///   - "All"（match all）
///   - 每个 plugin 一个 tab
/// 调用方可以传自己的 tabs 完全覆盖（例如 meee2 按归属人分类）。
export function defaultTabsFromSessions(sessions: Session[]): SidebarTab[] {
  const plugins = new Map<string, string>()
  for (const s of sessions) {
    if (!plugins.has(s.pluginId)) plugins.set(s.pluginId, s.pluginDisplayName)
  }
  const tabs: SidebarTab[] = [{ id: 'all', label: 'All' }]
  for (const [id, label] of plugins.entries()) {
    tabs.push({
      id,
      label,
      match: (s) => s.pluginId === id,
    })
  }
  return tabs
}
