import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { BoardState, ClientKind, Selection, Session } from '../types'
import { isOlderSession } from '../types'
import ChannelDetail from './ChannelDetail'
import {
  SidebarFilterMenu,
  loadFilterState,
  saveFilterState,
  type FilterState,
} from './SidebarFilterMenu'
import {
  SidebarTopNav,
  defaultTabsFromSessions,
  type SidebarTab,
} from './SidebarTopNav'
import {
  loadTitleOverrides,
  saveTitleOverride,
  loadPinnedSet,
  togglePinned,
} from '../sessionOverrides'
import { isDmChannelName } from '@meee1/board-core'
import { ExternalLink, Inbox, LogIn, LogOut, MoreHorizontal, Settings as SettingsIcon } from 'lucide-react'
import { SessionRowMenu, originalClientLabel } from './SessionRowMenu'
import { Tooltip } from './Tooltip'
import { UpdatePill } from './UpdatePill'
import {
  activateSession,
  closeSession,
  disconnectMeee360,
  fetchUserProfile,
  openMeee2Settings,
  openMeee360Connect,
  openMeee360Dashboard,
  spawnSession,
  type UserProfile,
} from '../api'
import { useToast } from '../App'

const CATEGORY_FILTER_KEY = 'meee2.sidebar.categoryFilter.v2'
const OLDER_SESSIONS_KEY = 'meee2.sidebar.olderSessionsExpanded.v1'
const COLLAPSED_PROJECTS_KEY = 'meee2.sidebar.collapsedProjects.v1'

/// Session 分类 key —— 动态从 session 列表里推导。规则：
/// - `com.meee2.plugin.claude` 这种"伞 plugin"内部按 clientKind 拆 (CLI/Desktop/Cowork)
/// - 其他 plugin（Cursor / Codex / OpenClaw / 第三方）每个 pluginId 自成一类
/// 这样既覆盖 plugin 维度（用户主问），又在 Claude 内部保留 source 区分。
type CategoryKey = string  // e.g. "claude:cli", "claude:desktop", "com.meee2.plugin.codex"

/// session.project 是 cwd 全路径；按 project basename 当 group key（与 Claude
/// Code app 的 sidebar 分组对齐）。
///   - `<...>/foo/.claude/worktrees/<wt>` → `foo`（worktree 归到父项目）
///   - 其他 → cwd 的 basename
/// （没有用 `~/projects/<name>` 这种 regex —— 比如
///   `~/projects/meee1_code/meee2` 的 basename 是 `meee2`，正确；regex 会
///   错把 `meee1_code` 当项目名。）
function projectGroupKey(s: Session): string {
  const raw = (s.project ?? '').replace(/\/+$/, '')
  if (!raw) return '(no project)'
  // 1) Claude worktree：`<...>/<project>/.claude/worktrees/<wt>` → `<project>`
  const wtIdx = raw.indexOf('/.claude/worktrees/')
  if (wtIdx > 0) {
    const before = raw.slice(0, wtIdx)
    const slash = before.lastIndexOf('/')
    const base = slash >= 0 ? before.slice(slash + 1) : before
    if (base) return base
  }
  // 2) fallback：basename
  const idx = raw.lastIndexOf('/')
  const base = idx >= 0 ? raw.slice(idx + 1) : raw
  return base || '(no project)'
}

function readCollapsedProjects(): Set<string> {
  try {
    const s = localStorage.getItem(COLLAPSED_PROJECTS_KEY)
    if (!s) return new Set()
    const arr = JSON.parse(s)
    if (Array.isArray(arr)) return new Set(arr.filter((x) => typeof x === 'string'))
  } catch {}
  return new Set()
}

function persistCollapsedProjects(set: Set<string>) {
  try { localStorage.setItem(COLLAPSED_PROJECTS_KEY, JSON.stringify([...set])) } catch {}
}

const CLAUDE_PLUGIN_ID = 'com.meee2.plugin.claude'
const CODEX_PLUGIN_ID = 'com.meee2.plugin.codex'
const CURSOR_PLUGIN_ID = 'com.meee2.plugin.cursor'
const OPENCLAW_PLUGIN_ID = 'com.meee2.plugin.openclaw'

/// 不同 plugin 的 row hover 强调色（hover 时一抹渐变背景）。frontend 默认值
/// 覆盖 plugin metadata 里的 pluginColor —— 让品牌色保持稳定（用户在
/// product spec 里点名 Claude 橙、Codex 蓝、Cursor 灰、OpenClaw 红）。
function accentForPlugin(pluginId: string, fallback: string): string {
  switch (pluginId) {
    case CLAUDE_PLUGIN_ID: return '#FF9500'
    case CODEX_PLUGIN_ID: return '#3B82F6'
    case CURSOR_PLUGIN_ID: return '#9CA3AF'
    case OPENCLAW_PLUGIN_ID: return '#EF4444'
    default: return fallback
  }
}

/// session 行左侧 status indicator 的 kind 判定：
///   - `live`      —— thinking / tooling / active / compacting，三点 typing 动效（绿）
///   - `attention` —— permissionRequired，单点橙色脉冲（用户需要点确认）
///   - `pending`   —— unread（status 从工作态转到休息态，Claude 刚回完一轮，
///                     待用户查看），单点蓝色脉冲。优先级低于 attention：
///                     permissionRequired + unread 同时成立时仍走 attention。
///   - `null`      —— idle / waitingForUser / completed / dead 等"无需关注"态
function liveDotKind(
  status: string,
  unread: boolean,
): 'live' | 'attention' | 'pending' | null {
  if (status === 'thinking' || status === 'tooling' ||
      status === 'active' || status === 'compacting') return 'live'
  if (status === 'permissionRequired') return 'attention'
  if (unread) return 'pending'
  return null
}

/// 把 session.clientKind 规范化（缺字段 / 未知值 → 'cli'，因为 cli 是默认）
function normalizeKind(k: string | null | undefined): ClientKind {
  if (k === 'desktop' || k === 'cowork') return k
  return 'cli'
}

/// 计算 session 的 category key：Claude 拆 sub-source，其他 plugin 用 pluginId
function categoryKey(s: Session): CategoryKey {
  if (s.pluginId === CLAUDE_PLUGIN_ID) {
    return `claude:${normalizeKind(s.clientKind)}`
  }
  return s.pluginId
}

const KIND_ICON: Record<ClientKind, string> = {
  cli: '⌨',
  desktop: '🖥',
  cowork: '🤝',
}

interface CategoryDescriptor {
  key: CategoryKey
  label: string  // "Claude CLI" / "Cursor" / "Codex" 等显示用
  icon?: string  // optional emoji
}

/// 把 category key 翻成显示文本 + icon。Claude sub-source 走专门 label，
/// 其他 plugin 用 pluginDisplayName（DTO 里有）。
function describeCategory(
  key: CategoryKey,
  pluginDisplayNames: Record<string, string>,
): CategoryDescriptor {
  if (key.startsWith('claude:')) {
    const sub = key.slice('claude:'.length) as ClientKind
    const sublabel = sub === 'cli' ? 'CLI' : sub === 'desktop' ? 'Desktop' : 'Cowork'
    return { key, label: `Claude · ${sublabel}`, icon: KIND_ICON[sub] }
  }
  return { key, label: pluginDisplayNames[key] ?? key, icon: undefined }
}

function readStoredCategoryFilter(): CategoryKey | 'all' {
  try {
    const s = localStorage.getItem(CATEGORY_FILTER_KEY)
    if (s) return s
  } catch {}
  return 'all'
}

function persistCategoryFilter(f: CategoryKey | 'all') {
  try { localStorage.setItem(CATEGORY_FILTER_KEY, f) } catch {}
}

function readOlderExpanded(): boolean {
  try {
    return localStorage.getItem(OLDER_SESSIONS_KEY) === '1'
  } catch {}
  return false
}

function persistOlderExpanded(v: boolean) {
  try { localStorage.setItem(OLDER_SESSIONS_KEY, v ? '1' : '0') } catch {}
}

const WIDTH_KEY = 'meee2.sidebar.width.v1'
const WIDTH_MIN = 260
const WIDTH_MAX = 900
const WIDTH_DEFAULT = 360

/// Sidebar collapse / expand 图标。Lucide 同款，三套：
///   - PanelLeftIcon       (面板 + 竖条，无箭头) → "rest"，默认显示
///   - PanelLeftCloseIcon  (面板 + ← 箭头)        → "hover" 时显示，sidebar 是 open 状态
///   - PanelLeftOpenIcon   (面板 + → 箭头)        → "hover" 时显示，sidebar 是 collapsed 状态
/// rest → hover 用 CSS `:hover` 切换 visibility（不走 React state 减少
/// 一层 setState 的 重渲染），button 里同时挂"rest"和"active"两个 icon。
/// 视觉上统一 14×14 / stroke 1.8 跟其它 sidebar 图标对齐。
function PanelLeftIcon() {
  return (
    <svg className="icon-rest" viewBox="0 0 24 24" fill="none"
         stroke="currentColor" strokeWidth="1.8"
         strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <rect x="3" y="3" width="18" height="18" rx="2"/>
      <path d="M9 3v18"/>
    </svg>
  )
}
function PanelLeftCloseIcon() {
  return (
    <svg className="icon-active" viewBox="0 0 24 24" fill="none"
         stroke="currentColor" strokeWidth="1.8"
         strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <rect x="3" y="3" width="18" height="18" rx="2"/>
      <path d="M9 3v18"/>
      <path d="m16 15-3-3 3-3"/>
    </svg>
  )
}
function PanelLeftOpenIcon() {
  return (
    <svg className="icon-active" viewBox="0 0 24 24" fill="none"
         stroke="currentColor" strokeWidth="1.8"
         strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <rect x="3" y="3" width="18" height="18" rx="2"/>
      <path d="M9 3v18"/>
      <path d="m14 9 3 3-3 3"/>
    </svg>
  )
}

function readStoredWidth(): number {
  try {
    const s = localStorage.getItem(WIDTH_KEY)
    if (!s) return WIDTH_DEFAULT
    const n = parseInt(s, 10)
    if (!Number.isFinite(n)) return WIDTH_DEFAULT
    return Math.min(Math.max(n, WIDTH_MIN), WIDTH_MAX)
  } catch {
    return WIDTH_DEFAULT
  }
}

function clampToViewport(w: number): number {
  const vw = typeof window !== 'undefined' ? window.innerWidth : 1200
  const max = Math.min(WIDTH_MAX, Math.floor(vw * 0.7))
  return Math.min(Math.max(w, WIDTH_MIN), max)
}

// 16x16 line icons — Feather-style, match the sidebar's neutral tone.
function EyeOpenIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8S1 12 1 12z" />
      <circle cx="12" cy="12" r="3" />
    </svg>
  )
}

function EyeClosedIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M17.94 17.94A10.94 10.94 0 0 1 12 20C5 20 1 12 1 12a21.77 21.77 0 0 1 5.17-6.17" />
      <path d="M22.54 12.88A21.82 21.82 0 0 0 23 12s-4-8-11-8a10.94 10.94 0 0 0-4.06.77" />
      <path d="M9.9 9.9a3 3 0 0 0 4.2 4.2" />
      <line x1="1" y1="1" x2="23" y2="23" />
    </svg>
  )
}

/// 按"最后一次交互时间"分到 Today / Yesterday / This week / Earlier 四个桶。
/// 桶的顺序是固定的（最近的在前）；空桶不返回。
///
/// 注意：最后一桶用 "Earlier" 而不是 "Older"，避免和外层折叠区
/// （`isOlderSession()` 派生，标签 "Older (N) 1h–24h"）字面撞车
/// —— 那个折叠区是按 idle 时长分的、和这里按日期分桶语义不同。
function groupSessionsByDate(list: Session[]): Array<[string, Session[]]> {
  const now = new Date()
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  const dayMs = 24 * 60 * 60 * 1000
  const yesterdayStart = startOfToday - dayMs
  const weekStart = startOfToday - 6 * dayMs

  const buckets: Record<string, Session[]> = {
    Today: [],
    Yesterday: [],
    'This week': [],
    Earlier: [],
  }
  const sorted = [...list].sort((a, b) => {
    const ta = a.lastActivity ? Date.parse(a.lastActivity) : 0
    const tb = b.lastActivity ? Date.parse(b.lastActivity) : 0
    return tb - ta
  })
  for (const s of sorted) {
    const ts = s.lastActivity ? Date.parse(s.lastActivity) : 0
    if (!ts) {
      buckets.Earlier.push(s)
    } else if (ts >= startOfToday) {
      buckets.Today.push(s)
    } else if (ts >= yesterdayStart) {
      buckets.Yesterday.push(s)
    } else if (ts >= weekStart) {
      buckets['This week'].push(s)
    } else {
      buckets.Earlier.push(s)
    }
  }
  // 保留桶序；空桶丢掉
  return (['Today', 'Yesterday', 'This week', 'Earlier'] as const)
    .map((k) => [k as string, buckets[k]] as [string, Session[]])
    .filter(([, arr]) => arr.length > 0)
}

/// 把 SidebarFilterMenu 上的多维过滤 + 排序应用到 session 列表。
/// 注意：传入的 sessions 已经经过现有的 categoryFilter（plugin 维度，sidebar
/// inline 那排 button），这里追加 status / project / lastActivity 过滤 + sortBy 排序。
function applyFilterMenu(sessions: Session[], f: FilterState): Session[] {
  const now = Date.now()
  const lastActivityCutoffMs = (() => {
    switch (f.lastActivity) {
      case '1h': return 60 * 60 * 1000
      case '24h': return 24 * 60 * 60 * 1000
      case '7d': return 7 * 24 * 60 * 60 * 1000
      default: return null
    }
  })()
  const matchStatus = (s: Session): boolean => {
    if (f.status === 'all') return true
    const st = s.status
    if (f.status === 'idle') return st === 'idle'
    // waitingForUser 和 permissionRequired 都算 "在等用户" —— 漏掉
    // permissionRequired 会让"等批 tool"的 session 在 waiting 视图里消失，
    // 而那其实是用户最该看的一种 waiting。
    if (f.status === 'waiting') {
      return st === 'waitingForUser' || st === 'permissionRequired'
    }
    if (f.status === 'active') {
      return st === 'thinking' || st === 'tooling' || st === 'spawning'
    }
    return true
  }
  const matchProject = (s: Session): boolean => {
    if (f.project === 'all') return true
    return projectGroupKey(s) === f.project
  }
  const matchPlugin = (s: Session): boolean => {
    if (f.plugin === 'all') return true
    return s.pluginId === f.plugin
  }
  const matchActivity = (s: Session): boolean => {
    if (lastActivityCutoffMs === null) return true
    const ts = s.lastActivity || s.startedAt
    if (!ts) return true  // 未知活跃时间 → 不卡
    const t = Date.parse(ts)
    if (Number.isNaN(t)) return true
    return now - t <= lastActivityCutoffMs
  }
  const filtered = sessions.filter(
    (s) => matchStatus(s) && matchProject(s) && matchPlugin(s) && matchActivity(s),
  )
  // sort
  const titleOf = (s: Session) => s.title.toLocaleLowerCase()
  const tsOf = (s: Session, key: 'startedAt' | 'lastActivity') => {
    const v = key === 'startedAt' ? s.startedAt : s.lastActivity
    if (!v) return 0
    const t = Date.parse(v)
    return Number.isNaN(t) ? 0 : t
  }
  switch (f.sortBy) {
    case 'title':
      filtered.sort((a, b) => titleOf(a).localeCompare(titleOf(b)))
      break
    case 'createdTime':
      filtered.sort((a, b) => tsOf(b, 'startedAt') - tsOf(a, 'startedAt'))
      break
    case 'lastActivity':
    default:
      filtered.sort((a, b) => tsOf(b, 'lastActivity') - tsOf(a, 'lastActivity'))
      break
  }
  return filtered
}

interface Props {
  state: BoardState | null
  selection: Selection
  open: boolean
  onOpen: () => void
  onClose: () => void
  onSelectionChange: (s: Selection) => void
  /** Count of embeddable elements currently on the canvas, keyed by sid. */
  onCanvasCounts: Record<string, number>
  /** sid → "刚从工作态转到休息态、还没被用户查看"。Sidebar 用它点亮蓝点，
   *  和 SessionOverlay 的红点共享同一个 set —— 用户点 row 后由 App 清除。 */
  unreadSids: Set<string>
  /** Request to insert a new embeddable card for this session. */
  onAddToCanvas: (sessionId: string) => void
  /** Request to remove all cards for this session from the canvas. */
  onHideFromCanvas: (sessionId: string) => void
  /** Bulk show / hide sessions on the canvas in one shot.
   *  - omit `sids` → operates on every session (top "Hide all" button)
   *  - pass `sids` → operates only on that subset (per-category toggle) */
  onBulkVisibility: (mode: 'show' | 'hide', sids?: string[]) => void
  /** "+ New session" 顶部按钮 —— 默认打开全局 AI assistant
   *  （meee360 风格：可询问全部 session 的整体问题，也能在某个目录下创建新 session）。 */
  onNewSession?: () => void
  /** 顶部 plugin 分类胶囊；不传 → 从当前 sessions 自动推导（按 plugin 分）。
   *  比如 meee360 可以传"按归属人"分类的 tabs 完全覆盖。 */
  tabsOverride?: SidebarTab[]
  /** project 分组 header 上的 + 按钮：在某个项目目录下起新 session。
   *  cwd 是该 project group 内任意一个 session 的 cwd 路径。 */
  onCreateInProject?: (cwd: string) => void
  /** 重命名一个 session（pencil icon → input）。 */
  onRenameSession?: (sessionId: string, newTitle: string) => Promise<void> | void
}

export default function Sidebar({
  state,
  selection,
  open,
  onOpen,
  onClose,
  onSelectionChange,
  onCanvasCounts,
  unreadSids,
  onAddToCanvas,
  onHideFromCanvas,
  onBulkVisibility,
  onNewSession,
  tabsOverride,
  onCreateInProject,
  onRenameSession,
}: Props) {
  const toast = useToast()
  const [width, setWidth] = useState<number>(readStoredWidth)
  const [categoryFilter, setCategoryFilter] = useState<CategoryKey | 'all'>(readStoredCategoryFilter)
  const [olderExpanded, setOlderExpanded] = useState<boolean>(readOlderExpanded)
  const [collapsedProjects, setCollapsedProjects] = useState<Set<string>>(readCollapsedProjects)
  const [filterState, setFilterStateRaw] = useState<FilterState>(loadFilterState)
  const [filterMenuOpen, setFilterMenuOpen] = useState(false)
  const [activeTabId, setActiveTabId] = useState<string>('all')
  const [titleOverrides, setTitleOverrides] = useState<Record<string, string>>(loadTitleOverrides)
  const [pinned, setPinned] = useState<Set<string>>(loadPinnedSet)
  const [renamingSid, setRenamingSid] = useState<string | null>(null)
  const [renameDraft, setRenameDraft] = useState<string>('')
  // 搜索：onToggleSearch 切换 input 可见性；input 显示时按 title / project basename
  // substring match 过滤 session list（client-side，立刻见效）。
  const [searchOpen, setSearchOpen] = useState<boolean>(false)
  const [searchQuery, setSearchQuery] = useState<string>('')
  const [userProfile, setUserProfile] = useState<UserProfile | null>(null)
  const [accountMenuOpen, setAccountMenuOpen] = useState(false)
  const searchInputRef = useRef<HTMLInputElement | null>(null)
  const accountMenuRef = useRef<HTMLDivElement | null>(null)
  const dragStartRef = useRef<{ x: number; w: number } | null>(null)

  const loadUserProfile = useCallback(() => {
    fetchUserProfile()
      .then(setUserProfile)
      .catch(() => setUserProfile(null))
  }, [])

  // override / pin 改动时同步（本组件外的修改也会触发，跨组件一致）
  useEffect(() => {
    const handler = () => {
      setTitleOverrides(loadTitleOverrides())
      setPinned(loadPinnedSet())
    }
    window.addEventListener('meee2:session-overrides-changed', handler)
    return () => window.removeEventListener('meee2:session-overrides-changed', handler)
  }, [])

  const displayTitle = useCallback(
    (s: Session) => titleOverrides[s.id] || s.title,
    [titleOverrides],
  )

  const startRename = useCallback((s: Session) => {
    setRenamingSid(s.id)
    setRenameDraft(displayTitle(s))
  }, [displayTitle])

  // ── Hover overlay menu ───────────────────────────────────────────
  // 每行只露一个 ⋯ 按钮（hover 时浮现），点开覆盖菜单（Open in / Pin /
  // Rename / Duplicate）。状态：当前打开菜单的 sid + anchor 按钮的 rect
  // （给 overlay 定位用）。
  const [menuForSid, setMenuForSid] = useState<string | null>(null)
  const [menuAnchorRect, setMenuAnchorRect] = useState<DOMRect | null>(null)
  const closeMenu = useCallback(() => {
    setMenuForSid(null)
    setMenuAnchorRect(null)
  }, [])

  const commitRename = useCallback(() => {
    if (!renamingSid) return
    const t = renameDraft.trim()
    saveTitleOverride(renamingSid, t || null)
    setRenamingSid(null)
    setRenameDraft('')
  }, [renamingSid, renameDraft])

  const cancelRename = useCallback(() => {
    setRenamingSid(null)
    setRenameDraft('')
  }, [])

  const setFilterState = useCallback((next: FilterState) => {
    setFilterStateRaw(next)
    saveFilterState(next)
  }, [])

  const toggleProjectCollapsed = useCallback((proj: string) => {
    setCollapsedProjects((prev) => {
      const next = new Set(prev)
      if (next.has(proj)) next.delete(proj)
      else next.add(proj)
      persistCollapsedProjects(next)
      return next
    })
  }, [])

  /// 按当前 sessions 推导出 category 列表（带计数）+ pluginId → displayName 索引。
  const categoryDescriptors = useMemo(() => {
    const names: Record<string, string> = {}
    const counts: Record<CategoryKey, number> = {}
    if (state) {
      for (const s of state.sessions) {
        names[s.pluginId] = s.pluginDisplayName
        const k = categoryKey(s)
        counts[k] = (counts[k] ?? 0) + 1
      }
    }
    // 按一个稳定的顺序展示：Claude sub-categories 先（cli/desktop/cowork），
    // 然后其他 plugin 按 displayName 字母序
    const claudeKeys = ['claude:cli', 'claude:desktop', 'claude:cowork'].filter(k => counts[k] > 0)
    const otherKeys = Object.keys(counts)
      .filter(k => !k.startsWith('claude:'))
      .sort((a, b) => (names[a] ?? a).localeCompare(names[b] ?? b))
    const orderedKeys = [...claudeKeys, ...otherKeys]
    const descs = orderedKeys.map(k => ({
      ...describeCategory(k, names),
      count: counts[k],
    }))
    return descs
  }, [state])

  /// 当前 filter 对应的 session 列表
  const filterByCategory = useCallback(
    (sessions: BoardState['sessions']) => {
      if (categoryFilter === 'all') return sessions
      return sessions.filter((s) => categoryKey(s) === categoryFilter)
    },
    [categoryFilter],
  )

  const onResizerMouseDown = useCallback((e: React.MouseEvent) => {
    e.preventDefault()
    dragStartRef.current = { x: e.clientX, w: width }
    document.body.style.cursor = 'ew-resize'
    document.body.style.userSelect = 'none'
  }, [width])

  useEffect(() => {
    function onMove(e: MouseEvent) {
      const s = dragStartRef.current
      if (!s) return
      // sidebar 在左侧：鼠标往右移 → width 增大
      const raw = s.w + (e.clientX - s.x)
      setWidth(clampToViewport(raw))
    }
    function onUp() {
      if (!dragStartRef.current) return
      dragStartRef.current = null
      document.body.style.cursor = ''
      document.body.style.userSelect = ''
      try {
        localStorage.setItem(WIDTH_KEY, String(width))
      } catch { /* localStorage unavailable */ }
    }
    window.addEventListener('mousemove', onMove)
    window.addEventListener('mouseup', onUp)
    return () => {
      window.removeEventListener('mousemove', onMove)
      window.removeEventListener('mouseup', onUp)
    }
  }, [width])

  // 窗口缩小时收紧 sidebar 宽度
  useEffect(() => {
    function onResize() {
      setWidth((w) => clampToViewport(w))
    }
    window.addEventListener('resize', onResize)
    return () => window.removeEventListener('resize', onResize)
  }, [])

  // 把 sidebar 当前渲染宽度发布到 :root 上的 CSS 变量。
  //   - 展开：用户拖拽存的 width
  //   - 折叠：0px（sidebar 整个收起，画板占满；按钮浮出在画板左上角）
  // .app 的 grid-template-columns 直接读这个 var，所以折叠 / 展开切换
  // 等于直接改 grid track 宽度，不再依赖 .sidebar 自身 width 属性。
  useEffect(() => {
    const px = open ? `${width}px` : '0px'
    document.documentElement.style.setProperty('--sidebar-width', px)
  }, [open, width])

  useEffect(() => {
    loadUserProfile()
    window.addEventListener('focus', loadUserProfile)
    return () => window.removeEventListener('focus', loadUserProfile)
  }, [loadUserProfile])

  useEffect(() => {
    if (!accountMenuOpen) return
    const onPointerDown = (event: PointerEvent) => {
      const node = accountMenuRef.current
      if (node && event.target instanceof Node && node.contains(event.target)) return
      setAccountMenuOpen(false)
    }
    document.addEventListener('pointerdown', onPointerDown, true)
    return () => document.removeEventListener('pointerdown', onPointerDown, true)
  }, [accountMenuOpen])

  const openDashboard = useCallback(async () => {
    try {
      await openMeee360Dashboard()
    } catch (err) {
      toast.push('error', (err as Error).message || 'Failed to open meee360')
    }
  }, [toast])

  const toggleMeee360Connection = useCallback(async () => {
    try {
      if (userProfile?.connected) {
        await disconnectMeee360()
        loadUserProfile()
        toast.push('success', 'Disconnected from meee360')
      } else {
        await openMeee360Connect()
      }
    } catch (err) {
      toast.push('error', (err as Error).message || 'Failed to update meee360 connection')
    }
  }, [loadUserProfile, toast, userProfile?.connected])

  const openSettings = useCallback(async () => {
    try {
      await openMeee2Settings()
    } catch (err) {
      toast.push('error', (err as Error).message || 'Failed to open settings')
    }
  }, [toast])

  const runAccountAction = useCallback((action: () => void | Promise<void>) => {
    setAccountMenuOpen(false)
    void action()
  }, [])

  // ── Collapsed-icon hover preview ───────────────────────────────────
  // Hover 折叠图标 → sidebar 以 fixed overlay 形式浮在 icon 下方（不进
  // grid 流，不挤画板）。鼠标移到 preview 上不消失；离开有 ~180ms 缓冲让
  // 用户可以从 icon 滑到 preview。点击 icon = `onOpen()` = 切回常驻态。
  //
  // 进出动画两段式：
  //   1) `hoverPreview` 控制是否在 DOM 里。
  //   2) `previewLeaving` 控制"在 DOM 里但走 fade-out 动画"。
  // scheduleClose 流程：180ms 宽限期 → setPreviewLeaving(true)
  //   触发 CSS exit 动画 → 120ms 后 setHoverPreview(false) 真正卸载。
  const [hoverPreview, setHoverPreview] = useState(false)
  const [previewLeaving, setPreviewLeaving] = useState(false)
  const hoverCloseTimerRef = useRef<number | null>(null)
  const exitTimerRef = useRef<number | null>(null)
  const cancelClose = () => {
    if (hoverCloseTimerRef.current !== null) {
      window.clearTimeout(hoverCloseTimerRef.current)
      hoverCloseTimerRef.current = null
    }
    if (exitTimerRef.current !== null) {
      window.clearTimeout(exitTimerRef.current)
      exitTimerRef.current = null
    }
    setPreviewLeaving(false)
  }
  const scheduleClose = () => {
    cancelClose()
    hoverCloseTimerRef.current = window.setTimeout(() => {
      hoverCloseTimerRef.current = null
      setPreviewLeaving(true)
      exitTimerRef.current = window.setTimeout(() => {
        setHoverPreview(false)
        setPreviewLeaving(false)
        exitTimerRef.current = null
      }, 120)
    }, 180)
  }
  const openPreview = () => {
    cancelClose()
    setHoverPreview(true)
  }
  // 一旦从 hover 切到 explicit-open（点击图标或别处触发 onOpen），关掉
  // preview 避免两个 panel 重叠出现。
  useEffect(() => {
    if (open && hoverPreview) {
      cancelClose()
      setHoverPreview(false)
    }
  }, [open, hoverPreview])
  useEffect(() => () => cancelClose(), [])

  const isPreview = !open && hoverPreview

  // session 选中后 sidebar 不再切到 detail 模式（transcript 现在浮在画板上）。
  // 只有 channel 选中才走 detail 视图。
  const inDetail = selection.kind === 'channel'

  // Always-visible floating toggle, fixed at top:8 left:80 (right of the
  // macOS traffic lights). One button serves both states:
  //   • Sidebar closed → click expands; hover shows the preview overlay.
  //   • Sidebar open   → click collapses; hover does nothing extra.
  // BoardWebWindowController.DragRegionWebView has a matching click-through
  // rect so this button receives clicks even though it sits inside the
  // 28pt window-drag band. Update both files together if the position
  // ever changes.
  const floatingToggle = (
    <Tooltip
      label={open ? 'Collapse sidebar' : 'Expand sidebar'}
      placement="bottom"
    >
      <button
        key="floating-toggle"
        className={'sidebar-collapsed-toggle' + (!open ? ' sidebar-collapsed-toggle--collapsed' : '')}
        onClick={() => {
          cancelClose()
          setHoverPreview(false)
          if (open) onClose()
          else onOpen()
        }}
        onMouseEnter={!open ? openPreview : undefined}
        onMouseLeave={!open ? scheduleClose : undefined}
        aria-label={open ? 'Collapse sidebar' : 'Expand sidebar'}
      >
        <PanelLeftIcon />
        {/* 只在折叠态挂 hover-active icon —— 展开时用户看到 sidebar 已经在那
            没必要再用 chevron 暗示方向；hover 也保持静态。 */}
        {!open && <PanelLeftOpenIcon />}
      </button>
    </Tooltip>
  )

  if (!open && !isPreview) {
    return floatingToggle
  }

  return (
    <>
    {floatingToggle}
    <aside
      className={
        'sidebar'
        + (isPreview ? ' sidebar--preview' : '')
        + (isPreview && previewLeaving ? ' sidebar--preview-leaving' : '')
      }
      style={isPreview ? undefined : { width }}
      onMouseEnter={isPreview ? cancelClose : undefined}
      onMouseLeave={isPreview ? scheduleClose : undefined}
      // Suppress the native context menu inside the sidebar so right-click is
      // ours to define (the per-row handler turns it into the SessionRowMenu).
      // 例外：rename input / 普通 input 上保留原生菜单，否则用户没法 paste。
      onContextMenu={(e) => {
        const t = e.target as HTMLElement | null
        const tag = t?.tagName?.toLowerCase()
        if (tag === 'input' || tag === 'textarea' || t?.isContentEditable) return
        e.preventDefault()
      }}
    >
      <div
        className="sidebar-resizer"
        onMouseDown={onResizerMouseDown}
        title="Drag to resize"
      />
      <div className="sidebar-header row space" style={{ position: 'relative' }}>
        <div className="row" style={{ gap: 6, alignItems: 'center' }}>
          {inDetail && (
            <Tooltip label="Back to session list">
              <button
                className="ghost"
                style={{ padding: '2px 6px' }}
                onClick={() => onSelectionChange({ kind: 'none' })}
                aria-label="Back to session list"
              >
                ‹
              </button>
            </Tooltip>
          )}
          {/* In detail view we show the section label so the back button has
           * context; the default "Inspector" label is just chrome and Claude
           * Code-style sidebars don't use a section header at all. */}
          {inDetail && (
            <span>{selection.kind === 'channel' ? 'Channel' : ''}</span>
          )}
        </div>
        {/* Header right side: codex-style "Update" pill 只在有新版时出现,
         * 平时空白(原本只有 fixed 的 sidebar-collapse toggle 浮在左侧
         * traffic-light 旁,header 右侧没东西竞争)。 */}
        <UpdatePill />
      </div>
      <div className="sidebar-body">
        {!state && <div className="muted">Loading…</div>}
        {state && selection.kind !== 'channel' && (() => {
          const tabs: SidebarTab[] = tabsOverride ?? defaultTabsFromSessions(state.sessions)
          // 找当前 active tab（防止 sessions 变了之后 activeTabId 没对应的 tab）
          const activeTab = tabs.find((t) => t.id === activeTabId) ?? tabs[0]
          return (
          <div className="col" style={{ gap: 4 }}>
            <SidebarTopNav
              tabs={tabs}
              activeTabId={activeTab?.id ?? 'all'}
              onTabChange={setActiveTabId}
              onNewSession={onNewSession ?? (() => { /* no-op */ })}
              onToggleSearch={() => {
                setSearchOpen((prev) => {
                  const next = !prev
                  // 关搜索时清空 query，避免列表保持过滤态
                  if (!next) setSearchQuery('')
                  // 开搜索时下一帧 focus input
                  if (next) requestAnimationFrame(() => searchInputRef.current?.focus())
                  return next
                })
              }}
            />
            {searchOpen && (
              <div className="sidebar-search">
                <span className="sidebar-search__icon" aria-hidden>
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none"
                       stroke="currentColor" strokeWidth="2"
                       strokeLinecap="round" strokeLinejoin="round">
                    <circle cx="11" cy="11" r="8"/>
                    <path d="m21 21-4.3-4.3"/>
                  </svg>
                </span>
                <input
                  ref={searchInputRef}
                  type="text"
                  className="sidebar-search__input"
                  placeholder="Filter session by title or project…"
                  value={searchQuery}
                  onChange={(e) => setSearchQuery(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Escape') {
                      setSearchQuery('')
                      setSearchOpen(false)
                      e.currentTarget.blur()
                    }
                  }}
                />
                {searchQuery && (
                  <Tooltip label="Clear search" shortcut="Esc">
                    <button
                      type="button"
                      className="sidebar-search__clear"
                      aria-label="Clear search"
                      onClick={() => {
                        setSearchQuery('')
                        searchInputRef.current?.focus()
                      }}
                    >
                      ×
                    </button>
                  </Tooltip>
                )}
              </div>
            )}
            <div className="section">
              {/* 顶部 header：标题 + 一个 toggle。当前至少有一张 card 在画布上 → "Hide all"；
                  全部不在 → "Show all"。按钮走 onBulkVisibility，由 Board 的 effect 一次性处理
                  所有 sids，避免单个触发跟 WS tick 竞争。 */}
              <div
                className="row space sidebar-legacy-h4-row"
                style={{ marginBottom: 6, alignItems: 'baseline' }}
              >
                <h4 style={{ margin: 0 }}>Sessions ({state.sessions.length})</h4>
                {(() => {
                  const total = state.sessions.length
                  if (total === 0) return null
                  // Top button respects the active category filter — when a
                  // filter is set, "Hide all" only hides sessions in that
                  // category. "All" → unscoped (legacy behaviour).
                  const scopedSessions =
                    categoryFilter === 'all'
                      ? state.sessions
                      : state.sessions.filter((s) => categoryKey(s) === categoryFilter)
                  if (scopedSessions.length === 0) return null
                  const anyOnCanvas = scopedSessions.some(
                    (s) => (onCanvasCounts[s.id] ?? 0) > 0,
                  )
                  const mode: 'show' | 'hide' = anyOnCanvas ? 'hide' : 'show'
                  const scopeLabel = categoryFilter === 'all' ? 'all' : 'category'
                  const sidsArg =
                    categoryFilter === 'all' ? undefined : scopedSessions.map((s) => s.id)
                  return (
                    <button
                      className="ghost"
                      style={{ padding: '2px 8px', fontSize: 10 }}
                      onClick={() => onBulkVisibility(mode, sidsArg)}
                      title={
                        mode === 'hide'
                          ? `Remove ${scopeLabel} session cards from the canvas`
                          : `Add ${scopeLabel} session cards back to the canvas`
                      }
                    >
                      {mode === 'hide' ? 'Hide all' : 'Show all'}
                    </button>
                  )
                })()}
              </div>
              {(() => {
                const tabFiltered = activeTab?.match
                  ? state.sessions.filter(activeTab.match)
                  : state.sessions
                let filtered = applyFilterMenu(
                  filterByCategory(tabFiltered),
                  filterState,
                )
                // 搜索：title / project basename / cwd substring 任一命中即保留
                // （case-insensitive）。trim 一下避免单纯空格触发"无匹配"空态。
                const q = searchQuery.trim().toLowerCase()
                if (q) {
                  filtered = filtered.filter((s) => {
                    const title = (titleOverrides[s.id] || s.title || '').toLowerCase()
                    const proj = projectGroupKey(s).toLowerCase()
                    const cwd = (s.project || '').toLowerCase()
                    return title.includes(q) || proj.includes(q) || cwd.includes(q)
                  })
                }
                // older（idle ≥ 1h，前端从 lastActivity 派生，见
                // types.ts:isOlderSession）只在 groupBy=date 模式下单独折叠
                // 成 "Older 1h–24h" 区。groupBy=project 时不再切分 —— 用户按
                // 项目找东西时，stale 的 session 应该跟同项目其它 session
                // 在一起，而不是被单独抽到底部一个独立折叠区。
                const partitionByDisplayGroup = filterState.groupBy === 'date'
                const primary = partitionByDisplayGroup
                  ? filtered.filter((s) => !isOlderSession(s))
                  : filtered
                const older = partitionByDisplayGroup
                  ? filtered.filter((s) => isOlderSession(s))
                  : []

                // 分组：依据 filterState.groupBy 选 project | date。
                // - project: 按 cwd basename 分组，组内保留传入顺序，组间按字母序
                // - date: 按 lastActivity 分到 Today / Yesterday / This week / Older 桶
                const groupSessions = (list: Session[]): Array<[string, Session[]]> => {
                  if (filterState.groupBy === 'date') {
                    return groupSessionsByDate(list)
                  }
                  const groups = new Map<string, Session[]>()
                  for (const s of list) {
                    const k = projectGroupKey(s)
                    let arr = groups.get(k)
                    if (!arr) { arr = []; groups.set(k, arr) }
                    arr.push(s)
                  }
                  return [...groups.entries()].sort((a, b) => a[0].localeCompare(b[0]))
                }

                const renderSessionRow = (s: Session) => {
                  const count = onCanvasCounts[s.id] ?? 0
                  const onCanvas = count > 0
                  // 选中 session 时 sidebar 仍然展示列表（transcript 浮在画板上），
                  // 当前行用 .is-selected 加视觉反馈。
                  const selected =
                    selection.kind === 'session' && selection.sessionId === s.id
                  const dot = liveDotKind(s.status, unreadSids.has(s.id))
                  const accent = accentForPlugin(s.pluginId, s.pluginColor)
                  return (
                    <div
                      key={s.id}
                      className={
                        'sidebar-session-row' +
                        (selected ? ' is-selected' : '') +
                        (menuForSid === s.id ? ' is-menu-open' : '')
                      }
                      style={{ ['--row-accent' as any]: accent }}
                      // Right-click 行为 = 点 ⋯ 按钮：打开 SessionRowMenu，定
                      // 位到鼠标坐标。给 menu 一个零宽 synthetic DOMRect，于是
                      // 它的 (top, left) 计算结果直接落在 (clientY+4, clientX)。
                      // 跳过 input / textarea，让 rename 输入框保留原生菜单。
                      onContextMenu={(e) => {
                        const t = e.target as HTMLElement | null
                        const tag = t?.tagName?.toLowerCase()
                        if (tag === 'input' || tag === 'textarea' || t?.isContentEditable) return
                        e.preventDefault()
                        e.stopPropagation()
                        const W = 220
                        const x = e.clientX
                        const y = e.clientY
                        const rect = {
                          top: y, bottom: y, left: x, right: x + W,
                          x, y, width: W, height: 0,
                          toJSON: () => ({}),
                        } as DOMRect
                        setMenuForSid(s.id)
                        setMenuAnchorRect(rect)
                      }}
                    >
                      <div
                        className="sidebar-session-row__main"
                        onClick={() =>
                          onSelectionChange({ kind: 'session', sessionId: s.id })
                        }
                      >
                        {dot === 'live' ? (
                          // 三个 sequential bounce 的小点 —— 比单个 pulsing
                          // 圆更直观传达"正在执行"。颜色复用 --live 的绿，
                          // 时序参考 transcript 的 tx-thinking-dots 但拆成
                          // 三个独立 dot 走 staggered delay。
                          <span className="status-dots-live" aria-hidden>
                            <span /><span /><span />
                          </span>
                        ) : (
                          <span
                            className={
                              'status-dot' +
                              (dot === 'attention' ? ' status-dot--attention' :
                                dot === 'pending' ? ' status-dot--pending' :
                                ' status-dot--off')
                            }
                            aria-hidden
                          />
                        )}
                        {(() => {
                          // Claude session 多 source（CLI/Desktop/Cowork）共用一个
                          // pluginColor，加 source icon 才能视觉上分清。其他 plugin
                          // 自己有独立 pluginColor 不需要补。
                          if (s.pluginId !== CLAUDE_PLUGIN_ID) return null
                          const k = normalizeKind(s.clientKind)
                          if (k === 'cli') return null
                          return (
                            <span
                              className="sidebar-session-row__kind"
                              title={k === 'desktop' ? 'Desktop' : 'Cowork'}
                            >
                              {KIND_ICON[k]}
                            </span>
                          )
                        })()}
                        {renamingSid === s.id ? (
                          <input
                            className="sidebar-session-row__rename-input"
                            autoFocus
                            value={renameDraft}
                            onChange={(e) => setRenameDraft(e.target.value)}
                            onClick={(e) => e.stopPropagation()}
                            onKeyDown={(e) => {
                              if (e.key === 'Enter') { e.preventDefault(); commitRename() }
                              else if (e.key === 'Escape') { e.preventDefault(); cancelRename() }
                            }}
                            onBlur={commitRename}
                          />
                        ) : (
                          <span className="sidebar-session-row__title">{displayTitle(s)}</span>
                        )}
                      </div>
                      <div className="sidebar-session-row__actions">
                        {s.inboxPending > 0 && (
                          <span
                            className="badge warn sidebar-session-row__inbox"
                            title={`${s.inboxPending} pending inbox message${s.inboxPending === 1 ? '' : 's'}`}
                          >
                            <Inbox size={11} aria-hidden /> {s.inboxPending}
                          </span>
                        )}
                        {/* Canvas 可见性 toggle —— 始终可见的状态指示器 + 一键
                         *  toggle。on canvas 时 eye-open 实色，off canvas 时
                         *  eye-off 半透明（hover 提亮）。比藏在 ⋯ 菜单深处的
                         *  Hide / Show 一击即得。 */}
                        <Tooltip label={onCanvas ? 'Hide from canvas' : 'Show on canvas'}>
                          <button
                            className="sidebar-icon-btn sidebar-session-row__visibility"
                            data-on-canvas={onCanvas ? 'true' : 'false'}
                            aria-label={onCanvas ? 'Hide from canvas' : 'Show on canvas'}
                            aria-pressed={onCanvas}
                            onClick={(e) => {
                              e.stopPropagation()
                              if (onCanvas) {
                                onHideFromCanvas(s.id)
                              } else {
                                onAddToCanvas(s.id)
                              }
                            }}
                          >
                            {onCanvas ? <EyeOpenIcon /> : <EyeClosedIcon />}
                          </button>
                        </Tooltip>
                        {/* hover 时唯一暴露 ⋯ 按钮。click 打开 SessionRowMenu
                         *  overlay，里面集成原本的 pin / rename / canvas 三键
                         *  + 新加的 Duplicate 与 Open in submenu。*/}
                        <Tooltip label="Actions">
                        <button
                          className="sidebar-icon-btn sidebar-session-row__more"
                          aria-label="Open session actions menu"
                          onClick={(e) => {
                            e.stopPropagation()
                            const rect = (e.currentTarget as HTMLButtonElement).getBoundingClientRect()
                            if (menuForSid === s.id) {
                              closeMenu()
                            } else {
                              setMenuForSid(s.id)
                              setMenuAnchorRect(rect)
                            }
                          }}
                        >
                          <MoreHorizontal size={14} aria-hidden />
                        </button>
                        </Tooltip>
                      </div>
                      {menuForSid === s.id && (
                        <SessionRowMenu
                          session={s}
                          isPinned={pinned.has(s.id)}
                          onClose={closeMenu}
                          anchorRect={menuAnchorRect}
                          onOpenInCanvas={() => {
                            // 加到 canvas（如果还没在）+ 选中 session 让 dock
                            // 弹出 + 默认展开。saveDockExpanded 让下次再切回
                            // 同样保持展开；TranscriptPanel 会自动 mount。
                            if (!onCanvas) onAddToCanvas(s.id)
                            onSelectionChange({ kind: 'session', sessionId: s.id })
                          }}
                          onOpenInOriginal={() => {
                            // claude desktop / cli session / codex session 全
                            // 走 BoardAPI.activateSession —— 后端按 clientKind
                            // dispatch（ClaudeDesktopActivator 走 claude://，
                            // CLI 走 TerminalJumper）。
                            activateSession(s.id).catch((err) => {
                              toast.push(
                                'error',
                                `Open in original failed: ${(err as Error).message ?? 'unknown'}`
                              )
                            })
                          }}
                          onTogglePin={() => {
                            const nowPinned = togglePinned(s.id)
                            toast.push(
                              'success',
                              nowPinned
                                ? `Pinned: ${displayTitle(s)}`
                                : `Unpinned: ${displayTitle(s)}`
                            )
                          }}
                          onRename={() => startRename(s)}
                          onDuplicate={() => {
                            // Duplicate = spawn 新 session in same cwd。
                            // 用 SessionDTO.project（cwd 全路径）作为 cwd。
                            const cwd = s.project
                            if (!cwd) {
                              toast.push('error', 'Cannot duplicate: source session has no cwd')
                              return
                            }
                            const shortId = s.id.slice(0, 8)
                            toast.push('info', `Duplicating session in ${cwd}…`)
                            spawnSession({ cwd })
                              .then(() => {
                                toast.push(
                                  'success',
                                  `New session spawned in ${cwd} (from ${shortId})`
                                )
                              })
                              .catch((err) => {
                                toast.push('error', `Spawn failed: ${(err as Error).message ?? 'unknown'}`)
                              })
                          }}
                          onHide={onCanvas ? () => {
                            // 把 sid 加进 dismissed 集合 + 把 canvas 上的 rect
                            // 删掉。下次状态刷新不会自动重建（Board.tsx:681）。
                            onHideFromCanvas(s.id)
                            toast.push('info', `Hidden: ${displayTitle(s)}`)
                          } : undefined}
                          onCloseSession={() => {
                            // SIGTERM 真实进程。Desktop / Cowork / external 后端会拒
                            // （没 pid），把 toast 翻译成"自己回宿主 app 关"。
                            const shortId = s.id.slice(0, 8)
                            const name = displayTitle(s)
                            closeSession(s.id)
                              .then((r) => {
                                if (r.ok) {
                                  toast.push(
                                    'success',
                                    r.alreadyDead
                                      ? `${name} (${shortId}) was already gone — removed from board`
                                      : `Closed ${name} (${shortId})`
                                  )
                                  return
                                }
                                if (r.errorCode === 'no_pid') {
                                  // Desktop / Cowork / external — 提示用户回原 app 关
                                  toast.push(
                                    'error',
                                    `Can't close ${name} from here — please close it in ${originalClientLabel(s)} yourself.`
                                  )
                                  return
                                }
                                toast.push(
                                  'error',
                                  `Couldn't close ${name} (${r.errorCode}): ${r.error ?? 'unknown error'}. Try closing it manually in ${originalClientLabel(s)}.`
                                )
                              })
                              .catch((err) => {
                                toast.push(
                                  'error',
                                  `Close failed: ${(err as Error).message ?? 'unknown'}. Close it manually in ${originalClientLabel(s)}.`
                                )
                              })
                          }}
                        />
                      )}
                    </div>
                  )
                }

                const hasFilter =
                  filterState.status !== 'all' ||
                  filterState.project !== 'all' ||
                  filterState.plugin !== 'all' ||
                  filterState.lastActivity !== 'all'

                const renderProjectGroup = (
                  groupKey: string,
                  list: Session[],
                  options?: { dimmed?: boolean; isFirst?: boolean },
                ) => {
                  const collapsed = collapsedProjects.has(groupKey)
                  // groupBy=project 时，从组内任一 session 拿 cwd 给 + 按钮用
                  const sampleCwd =
                    filterState.groupBy === 'project' && list[0]?.project
                      ? list[0].project
                      : null
                  return (
                    <div
                      key={groupKey}
                      className={
                        'sidebar-project-group' +
                        (options?.dimmed ? ' is-dimmed' : '') +
                        (collapsed ? ' is-collapsed' : '')
                      }
                    >
                      <div
                        className="sidebar-project-group__header"
                        onClick={() => toggleProjectCollapsed(groupKey)}
                        title={collapsed ? 'Expand' : 'Collapse'}
                        role="button"
                      >
                        <span className="sidebar-project-group__name">{groupKey}</span>
                        <svg
                          className="sidebar-project-group__chevron"
                          width="11" height="11" viewBox="0 0 12 12" fill="none"
                          aria-hidden
                        >
                          <path
                            d={collapsed ? 'M4.5 3l3 3-3 3' : 'M3 4.5l3 3 3-3'}
                            stroke="currentColor" strokeWidth="1.6"
                            strokeLinecap="round" strokeLinejoin="round"
                          />
                        </svg>
                        <span className="sidebar-project-group__spacer" />
                        {sampleCwd && onCreateInProject && (
                          <Tooltip label={`New session in ${groupKey}`}>
                            <button
                              className="sidebar-project-group__add"
                              onClick={(e) => {
                                e.stopPropagation()
                                onCreateInProject(sampleCwd)
                              }}
                              aria-label={`New session in ${groupKey}`}
                            >
                              <svg width="13" height="13" viewBox="0 0 24 24" fill="none">
                                <path d="M12 5v14m-7-7h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
                              </svg>
                            </button>
                          </Tooltip>
                        )}
                        {/* Global filter trigger lives only on the first project
                         * group's top-right; data layer is unchanged (filter is
                         * still global). Hover-only chrome — same opacity 0→1
                         * pattern as `__add`. */}
                        {options?.isFirst && state && (
                          <div
                            className="sidebar-project-group__filter-wrap"
                            onClick={(e) => e.stopPropagation()}
                          >
                            <Tooltip label="Filter / Group / Sort">
                              <button
                                className={
                                  'sidebar-project-group__filter' +
                                  (filterMenuOpen || hasFilter ? ' is-active' : '')
                                }
                                onClick={() => setFilterMenuOpen((v) => !v)}
                                aria-label="Filter, group, sort"
                              >
                                <svg width="13" height="13" viewBox="0 0 24 24" fill="none">
                                  <path d="M4 6h16M7 12h10M10 18h4"
                                        stroke="currentColor" strokeWidth="2"
                                        strokeLinecap="round"/>
                                </svg>
                                {hasFilter && (
                                  <span className="filter-dot" aria-hidden />
                                )}
                              </button>
                            </Tooltip>
                            {filterMenuOpen && (
                              <SidebarFilterMenu
                                state={filterState}
                                onChange={setFilterState}
                                projects={Array.from(
                                  new Set(state.sessions.map(projectGroupKey)),
                                ).sort()}
                                plugins={Array.from(
                                  state.sessions.reduce((m, s) => {
                                    if (!m.has(s.pluginId))
                                      m.set(s.pluginId, s.pluginDisplayName)
                                    return m
                                  }, new Map<string, string>()).entries(),
                                ).map(([id, label]) => ({ id, label }))}
                                onClose={() => setFilterMenuOpen(false)}
                              />
                            )}
                          </div>
                        )}
                      </div>
                      {!collapsed && (
                        <div className="sidebar-project-group__body">
                          {list.map(renderSessionRow)}
                        </div>
                      )}
                    </div>
                  )
                }

                if (filtered.length === 0) {
                  // Empty filter result: render a single header so the user
                  // can still reach the Filter / Sort menu and undo what
                  // they set. We don't reuse `renderProjectGroup` here
                  // because the regular header keeps chrome (chevron / add
                  // / filter) hover-only — when the body is empty there's
                  // nothing visible to hover, so the filter trigger has to
                  // be always-visible. "Recents" is the plain-language
                  // label since there's no project / date group to name.
                  return (
                    <div className="sidebar-project-group sidebar-project-group--empty">
                      <div className="sidebar-project-group__header" role="presentation">
                        <span className="sidebar-project-group__name">Recents</span>
                        <span className="sidebar-project-group__spacer" />
                        {state && (
                          <div
                            className="sidebar-project-group__filter-wrap"
                            onClick={(e) => e.stopPropagation()}
                          >
                            <Tooltip label="Filter / Group / Sort">
                              <button
                                className={
                                  'sidebar-project-group__filter is-pinned' +
                                  (filterMenuOpen || hasFilter ? ' is-active' : '')
                                }
                                onClick={() => setFilterMenuOpen((v) => !v)}
                                aria-label="Filter, group, sort"
                              >
                                <svg width="13" height="13" viewBox="0 0 24 24" fill="none">
                                  <path d="M4 6h16M7 12h10M10 18h4"
                                        stroke="currentColor" strokeWidth="2"
                                        strokeLinecap="round"/>
                                </svg>
                                {hasFilter && <span className="filter-dot" aria-hidden />}
                              </button>
                            </Tooltip>
                            {filterMenuOpen && (
                              <SidebarFilterMenu
                                state={filterState}
                                onChange={setFilterState}
                                projects={Array.from(
                                  new Set(state.sessions.map(projectGroupKey)),
                                ).sort()}
                                plugins={Array.from(
                                  state.sessions.reduce((m, s) => {
                                    if (!m.has(s.pluginId))
                                      m.set(s.pluginId, s.pluginDisplayName)
                                    return m
                                  }, new Map<string, string>()).entries(),
                                ).map(([id, label]) => ({ id, label }))}
                                onClose={() => setFilterMenuOpen(false)}
                              />
                            )}
                          </div>
                        )}
                      </div>
                      <div
                        className="sidebar-project-group__body muted"
                        style={{ padding: '12px 8px', fontSize: 11 }}
                      >
                        No sessions for this filter.
                      </div>
                    </div>
                  )
                }
                const primaryGroups = groupSessions(primary)
                // 外层折叠区已经表达了时间维度（"1h–24h" 这条尾标签）：
                //   - groupBy=date：里面不再切日期子桶（否则等于把"1h–24h"
                //     再翻译成 "Today / This week" 贴一遍），直接 flat 列表。
                //   - groupBy=project：按 project 分桶仍有信息量（看哪个项目
                //     堆了 stale session），保留 groupSessions。
                const olderGroups: Array<[string, Session[]]> =
                  filterState.groupBy === 'date'
                    ? []
                    : groupSessions(older)
                // Pinned: 从全部 sessions 里按 pin 顺序拿（不受 tab/filter 限制——
                // pinned 就是用户长期关注，全局展示更合理）
                const pinnedSessions = state.sessions.filter((s) => pinned.has(s.id))
                return (
                  <>
                    <div className="sidebar-pinned-section">Pinned</div>
                    {pinnedSessions.length === 0 ? (
                      <div className="sidebar-pinned-empty">
                        <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                          <path d="M12 2v6m-3-1l3 3 3-3M5 13c0-2.5 2-5 7-5s7 2.5 7 5c0 1.5-1 2-3 2H8c-2 0-3-.5-3-2zM10 15v5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                        </svg>
                        <span>Drag pin icon on a session to pin it</span>
                      </div>
                    ) : (
                      <div className="sidebar-project-group__body" style={{ marginBottom: 8 }}>
                        {pinnedSessions.map(renderSessionRow)}
                      </div>
                    )}
                    {primaryGroups.map(([k, list], idx) =>
                      renderProjectGroup(k, list, { isFirst: idx === 0 }),
                    )}
                    {older.length > 0 && (
                      <div
                        className={
                          'sidebar-project-group is-dimmed' +
                          (olderExpanded ? '' : ' is-collapsed')
                        }
                      >
                        {/* Re-use the same project-group header chrome so
                         * Today / Earlier / Older read as the same visual
                         * family. Difference: Older keeps a right-aligned
                         * "1h–24h" hint as always-visible metadata (not
                         * hover-only); count is dropped to match every other
                         * header. */}
                        <div
                          className="sidebar-project-group__header"
                          onClick={() => {
                            setOlderExpanded((v) => {
                              persistOlderExpanded(!v)
                              return !v
                            })
                          }}
                          title="Sessions idle for more than 1 hour"
                          role="button"
                        >
                          <span className="sidebar-project-group__name">
                            Older
                          </span>
                          <svg
                            className="sidebar-project-group__chevron"
                            width="11" height="11" viewBox="0 0 12 12" fill="none"
                            aria-hidden
                          >
                            <path
                              d={olderExpanded ? 'M3 4.5l3 3 3-3' : 'M4.5 3l3 3-3 3'}
                              stroke="currentColor" strokeWidth="1.6"
                              strokeLinecap="round" strokeLinejoin="round"
                            />
                          </svg>
                          <span className="sidebar-project-group__spacer" />
                          <span className="sidebar-project-group__hint">
                            1h–24h
                          </span>
                        </div>
                        {olderExpanded && (
                          <div className="sidebar-project-group__body">
                            {filterState.groupBy === 'date'
                              ? older.map(renderSessionRow)
                              : olderGroups.map(([k, list]) =>
                                  renderProjectGroup(k, list, { dimmed: true }),
                                )}
                          </div>
                        )}
                      </div>
                    )}
                  </>
                )
              })()}
            </div>
            <div className="section">
              {(() => {
                // DM channels (`dm-…`) are visualised as card↔card arrows on
                // the canvas and are intentionally hidden from this listing
                // -- the user clicks the line to open one.
                const visibleChannels = state.channels.filter(
                  (c) => !isDmChannelName(c.name),
                )
                return (
                  <>
                    <h4>Channels ({visibleChannels.length})</h4>
                    {visibleChannels.length === 0 && (
                      <div className="muted">No channels yet.</div>
                    )}
                    {visibleChannels.map((ch) => {
                      // displayName 是 issue #24 加的"友好名"，UI 优先展示它，
                      // 但 canonical name 还是 channel id（hover 上去能看到原名）
                      const label = ch.displayName?.trim() || ch.name
                      return (
                        <div
                          key={ch.name}
                          className="row space"
                          style={{ marginBottom: 4, cursor: 'pointer' }}
                          title={label !== ch.name ? `id: ${ch.name}` : undefined}
                          onClick={() =>
                            onSelectionChange({ kind: 'channel', channelName: ch.name })
                          }
                        >
                          <span>{label}</span>
                          <span className="mono muted">
                            {ch.members.length}m · {ch.mode}
                            {ch.pendingCount > 0 ? ` ·⏳${ch.pendingCount}` : ''}
                          </span>
                        </div>
                      )
                    })}
                  </>
                )
              })()}
            </div>
          </div>
          )
        })()}
        {state && selection.kind === 'channel' && (
          <ChannelDetail state={state} channelName={selection.channelName} />
        )}
      </div>
      {/* ── 底部用户行（mirror Settings > User meee360 identity） ───────── */}
      <div className="sidebar-footer" ref={accountMenuRef}>
        {accountMenuOpen && (
          <div className="sidebar-account-menu" role="menu">
            <div className="sidebar-account-menu-user">
              <span className="sidebar-footer-user-avatar" aria-hidden>
                {userProfile?.userAvatarUrl ? (
                  <img
                    className="sidebar-footer-user-avatar-img"
                    src={userProfile.userAvatarUrl}
                    alt=""
                  />
                ) : (
                  <span className="sidebar-footer-user-initials">
                    {userProfile?.initials ?? '?'}
                  </span>
                )}
              </span>
              <span className="sidebar-account-menu-user-text">
                {userProfile?.connected ? (userProfile.userEmail || userProfile.displayName) : 'Not connected'}
              </span>
            </div>
            <div className="sidebar-account-menu-separator" />
            {userProfile?.connected ? (
              <button
                className="sidebar-account-menu-item"
                type="button"
                role="menuitem"
                onClick={() => runAccountAction(openDashboard)}
              >
                <ExternalLink size={17} strokeWidth={1.75} aria-hidden />
                <span>meee360</span>
              </button>
            ) : (
              <button
                className="sidebar-account-menu-item"
                type="button"
                role="menuitem"
                onClick={() => runAccountAction(toggleMeee360Connection)}
              >
                <LogIn size={17} strokeWidth={1.75} aria-hidden />
                <span>Login</span>
              </button>
            )}
            <button
              className="sidebar-account-menu-item"
              type="button"
              role="menuitem"
              onClick={() => runAccountAction(openSettings)}
            >
              <SettingsIcon size={17} strokeWidth={1.75} aria-hidden />
              <span>Settings</span>
            </button>
            {userProfile?.connected && (
              <>
                <div className="sidebar-account-menu-separator" />
                <button
                  className="sidebar-account-menu-item"
                  type="button"
                  role="menuitem"
                  onClick={() => runAccountAction(toggleMeee360Connection)}
                >
                  <LogOut size={17} strokeWidth={1.75} aria-hidden />
                  <span>Logout</span>
                </button>
              </>
            )}
          </div>
        )}
        <button
          className={'sidebar-footer-user' + (accountMenuOpen ? ' sidebar-footer-user--open' : '')}
          type="button"
          aria-haspopup="menu"
          aria-expanded={accountMenuOpen}
          onClick={() => setAccountMenuOpen((prev) => !prev)}
        >
          <span className="sidebar-footer-user-avatar" aria-hidden>
            {userProfile?.userAvatarUrl ? (
              <img
                className="sidebar-footer-user-avatar-img"
                src={userProfile.userAvatarUrl}
                alt=""
              />
            ) : (
              <span className="sidebar-footer-user-initials">
                {userProfile?.initials ?? '?'}
              </span>
            )}
          </span>
          <span className="sidebar-footer-user-name">
            {userProfile?.connected ? userProfile.displayName : 'Not connected'}
          </span>
        </button>
      </div>
    </aside>
    </>
  )
}
