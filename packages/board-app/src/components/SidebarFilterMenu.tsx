import { useEffect, useRef, useState } from 'react'

/**
 * Sidebar 顶部的 filter/sort 下拉菜单——视觉对齐 Claude Code 的 group-by 菜单：
 *
 *   ┌─────────────────────────────┐
 *   │ Status         Active     › │
 *   │ Project        All        › │
 *   │ Plugin         All        › │
 *   │ Last activity  All        › │
 *   ├─────────────────────────────┤
 *   │ Group by       Project    › │
 *   │ Sort by        Activity   › │
 *   └─────────────────────────────┘
 *
 * 每个 row 是一个可点的"切换"——点击后内联展开它的所有可选值（radio 列表）。
 * 不需要复杂的子菜单 popup，纵向展开即可，符合移动/桌面两端的人体工学。
 */

export type StatusFilterValue = 'all' | 'active' | 'idle' | 'waiting'
export type LastActivityValue = 'all' | '1h' | '24h' | '7d'
export type SortByValue = 'lastActivity' | 'createdTime' | 'title'
export type GroupByValue = 'none' | 'project' | 'date'

export interface FilterState {
  status: StatusFilterValue
  project: string  // "all" 或具体 project name
  plugin: string   // "all" 或具体 pluginId
  lastActivity: LastActivityValue
  groupBy: GroupByValue
  sortBy: SortByValue
}

interface PluginOption {
  id: string
  label: string
}

interface Props {
  state: FilterState
  onChange: (next: FilterState) => void
  /** 当前 board 上有的 project basenames（用于 Project 子选项） */
  projects: string[]
  /** 当前 board 上有的 plugin（id + 显示名） */
  plugins: PluginOption[]
  /** 关闭菜单 */
  onClose: () => void
}

const STATUS_OPTIONS: Array<{ value: StatusFilterValue; label: string }> = [
  { value: 'all', label: 'All' },
  { value: 'active', label: 'Active' },
  { value: 'idle', label: 'Idle' },
  { value: 'waiting', label: 'Waiting' },
]

const LAST_ACTIVITY_OPTIONS: Array<{ value: LastActivityValue; label: string }> = [
  { value: 'all', label: 'All' },
  { value: '1h', label: 'Last 1h' },
  { value: '24h', label: 'Last 24h' },
  { value: '7d', label: 'Last 7d' },
]

const GROUP_BY_OPTIONS: Array<{ value: GroupByValue; label: string }> = [
  { value: 'none', label: 'None' },
  { value: 'project', label: 'Project' },
  { value: 'date', label: 'Date (last activity)' },
]

const SORT_BY_OPTIONS: Array<{ value: SortByValue; label: string }> = [
  { value: 'lastActivity', label: 'Last activity' },
  { value: 'createdTime', label: 'Created time' },
  { value: 'title', label: 'Title' },
]

export function SidebarFilterMenu({
  state,
  onChange,
  projects,
  plugins,
  onClose,
}: Props) {
  const [expanded, setExpanded] = useState<keyof FilterState | null>(null)
  const ref = useRef<HTMLDivElement | null>(null)

  // 点空白处关闭
  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        onClose()
      }
    }
    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [onClose])

  const projectOptions = [
    { value: 'all', label: 'All' },
    ...projects.map((p) => ({ value: p, label: p })),
  ]
  const pluginOptions = [
    { value: 'all', label: 'All' },
    ...plugins.map((p) => ({ value: p.id, label: p.label })),
  ]

  const labelFor = (key: keyof FilterState): string => {
    const v = state[key]
    switch (key) {
      case 'status':
        return STATUS_OPTIONS.find((o) => o.value === v)?.label ?? 'All'
      case 'project':
        return v === 'all' ? 'All' : v
      case 'plugin':
        return v === 'all'
          ? 'All'
          : plugins.find((p) => p.id === v)?.label ?? v
      case 'lastActivity':
        return LAST_ACTIVITY_OPTIONS.find((o) => o.value === v)?.label ?? 'All'
      case 'groupBy':
        return GROUP_BY_OPTIONS.find((o) => o.value === v)?.label ?? 'None'
      case 'sortBy':
        return SORT_BY_OPTIONS.find((o) => o.value === v)?.label ?? 'Last activity'
      default:
        return ''
    }
  }

  const isActiveValue = (key: keyof FilterState): boolean => {
    const v = state[key]
    if (key === 'status') return v !== 'all'
    if (key === 'project') return v !== 'all'
    if (key === 'plugin') return v !== 'all'
    if (key === 'lastActivity') return v !== 'all'
    return false  // groupBy / sortBy 没有"激活"概念，灰色显示就行
  }

  const renderRow = (
    key: keyof FilterState,
    label: string,
    options: Array<{ value: string; label: string }>,
    onSelect: (value: string) => void,
  ) => {
    const isExpanded = expanded === key
    return (
      <div className="sf-row-wrap" key={key}>
        <button
          className="sf-row"
          onClick={() => setExpanded(isExpanded ? null : key)}
        >
          <span className="sf-row-label">{label}</span>
          <span
            className={
              'sf-row-value' + (isActiveValue(key) ? ' sf-row-value--active' : '')
            }
          >
            {labelFor(key)}
          </span>
          <svg className="sf-chevron" width="10" height="10" viewBox="0 0 12 12" fill="none">
            <path
              d={isExpanded ? 'M3 7.5l3-3 3 3' : 'M4.5 3l3 3-3 3'}
              stroke="currentColor"
              strokeWidth="1.4"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </button>
        {isExpanded && (
          <div className="sf-options">
            {options.map((opt) => {
              const selected = String(state[key]) === opt.value
              return (
                <button
                  key={opt.value}
                  className={'sf-option' + (selected ? ' sf-option--selected' : '')}
                  onClick={() => {
                    onSelect(opt.value)
                    setExpanded(null)
                  }}
                >
                  <span className="sf-option-check" aria-hidden>
                    {selected ? '✓' : ''}
                  </span>
                  <span>{opt.label}</span>
                </button>
              )
            })}
          </div>
        )}
      </div>
    )
  }

  return (
    <div className="sidebar-filter-menu" ref={ref}>
      {renderRow('status', 'Status', STATUS_OPTIONS, (v) =>
        onChange({ ...state, status: v as StatusFilterValue }),
      )}
      {renderRow('project', 'Project', projectOptions, (v) =>
        onChange({ ...state, project: v }),
      )}
      {renderRow('plugin', 'Plugin', pluginOptions, (v) =>
        onChange({ ...state, plugin: v }),
      )}
      {renderRow('lastActivity', 'Last activity', LAST_ACTIVITY_OPTIONS, (v) =>
        onChange({ ...state, lastActivity: v as LastActivityValue }),
      )}
      <div className="sf-divider" />
      {renderRow('groupBy', 'Group by', GROUP_BY_OPTIONS, (v) =>
        onChange({ ...state, groupBy: v as GroupByValue }),
      )}
      {renderRow('sortBy', 'Sort by', SORT_BY_OPTIONS, (v) =>
        onChange({ ...state, sortBy: v as SortByValue }),
      )}
    </div>
  )
}

export const DEFAULT_FILTER_STATE: FilterState = {
  status: 'all',
  project: 'all',
  plugin: 'all',
  lastActivity: 'all',
  groupBy: 'none',
  sortBy: 'lastActivity',
}

const STORAGE_KEY = 'meee2.sidebar.filterState.v2'

export function loadFilterState(): FilterState {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return DEFAULT_FILTER_STATE
    const parsed = JSON.parse(raw) as Partial<FilterState>
    return { ...DEFAULT_FILTER_STATE, ...parsed }
  } catch {
    return DEFAULT_FILTER_STATE
  }
}

export function saveFilterState(s: FilterState) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(s))
  } catch {
    /* localStorage unavailable */
  }
}
