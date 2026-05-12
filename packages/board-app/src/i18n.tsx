import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'

export type Locale = 'en' | 'zh-CN'

const LOCALE_STORAGE_KEY = 'meee2.locale.v1'

type Dictionary = Record<string, string>

const dictionaries: Record<Locale, Dictionary> = {
  en: {
    'surface.cockpit.label': 'Cockpit',
    'surface.cockpit.description': 'Personal AI work surface',
    'surface.team.label': 'Team Radar',
    'surface.team.description': 'Team-visible session radar',
    'surface.workrooms.label': 'Workroom',
    'surface.workrooms.description': 'Handoff and rescue surface',
    'surface.review.label': 'Review',
    'surface.review.description': 'Evidence and reviewer context',
    'surface.memory.label': 'Memory',
    'surface.memory.description': 'Standup and AI work memory',
    'surface.map.label': 'Session Map',
    'surface.map.description': 'Spatial session map',
    'scope.personal': 'Personal',
    'scope.team': 'Team',
    'scope.workspace': 'Workspace',
    'action.refresh': 'Refresh',
    'action.settings': 'Settings',
    'action.jumpBack': 'Jump back',
    'action.showInMap': 'Show in Session Map',
    'action.cancel': 'Cancel',
    'action.save': 'Save',
    'action.create': 'Create',
    'action.delete': 'Delete',
    'cockpit.kicker': 'Personal AI Cockpit',
    'cockpit.title': 'AI Work in Progress',
    'cockpit.subtitle': 'Local sessions first: status, evidence, risks, and jump-back points.',
    'cockpit.search': 'Search repo, session, provider, status, or latest message',
    'cockpit.loading': 'Loading local sessions...',
    'cockpit.sessions': 'sessions',
    'cockpit.matching': 'matching sessions',
    'status.permissionRequired': 'Permission',
    'status.waitingForUser': 'Waiting',
    'status.tooling': 'Tooling',
    'status.thinking': 'Thinking',
    'status.compacting': 'Compacting',
    'status.completed': 'Completed',
    'status.dead': 'Failed',
    'time.none': 'No activity',
    'time.justNow': 'just now',
    'time.minutesAgo': '{count}m ago',
    'time.hoursAgo': '{count}h ago',
    'time.daysAgo': '{count}d ago',
    'work.search': 'Search repo, session, provider, status, or latest message',
    'work.team.kicker': 'Phase 2 · Selective Sync',
    'work.team.title': 'Team AI Radar',
    'work.team.subtitle': 'Choose what local AI work becomes team-visible without exposing full transcripts by default.',
    'work.workrooms.kicker': 'Phase 3 · Handoff',
    'work.workrooms.title': 'Workroom & Handoff',
    'work.workrooms.subtitle': 'Collect one or more real sessions into a temporary rescue, review, or handoff surface.',
    'work.review.kicker': 'Phase 4 · Evidence',
    'work.review.title': 'Review Room',
    'work.review.subtitle': 'Review PR-facing evidence from related AI sessions before reading raw transcript.',
    'work.memory.kicker': 'Phase 5 · Memory',
    'work.memory.title': 'Team Memory & Audit',
    'work.memory.subtitle': 'Turn session history into standups, retention controls, and audit-ready AI work memory.',
    'workmap.kicker': 'Spatial Work Surface',
    'workmap.title': 'Session Map',
    'workmap.subtitle': 'A spatial session map for arranging live AI work, evidence, and handoff context.',
    'workmap.switching': 'Switching map',
    'workmap.saving': 'Saving map',
    'workmap.saved': 'Map saved',
    'map.new': 'New map',
    'map.create': 'Create map',
    'map.delete': 'Delete map',
    'map.rename': 'Rename',
    'map.arrange': 'Arrange',
    'map.default': 'Default',
    'map.namePlaceholder': 'Map name',
    'map.createSubtitle': 'Name it and choose where it lives.',
    'map.deleteSubtitle': 'This only removes the map container.',
    'map.deleteBody': 'This removes the map layout and memberships. Sessions are not deleted.',
    'settings.title': 'Settings',
    'settings.subtitle': 'Theme, language, sync, maps, and assistant behavior.',
    'settings.appearance': 'Appearance',
    'settings.appearanceCaption': 'Use one theme and language across all work surfaces.',
    'settings.theme': 'Theme',
    'settings.theme.system': 'System',
    'settings.theme.light': 'Light',
    'settings.theme.dark': 'Dark',
    'settings.language': 'Language',
    'settings.language.en': 'English',
    'settings.language.zh-CN': '中文',
  },
  'zh-CN': {
    'surface.cockpit.label': 'Cockpit',
    'surface.cockpit.description': '个人 AI 工作面',
    'surface.team.label': 'Team Radar',
    'surface.team.description': '团队可见 session 态势',
    'surface.workrooms.label': 'Workroom',
    'surface.workrooms.description': '接力与救援工作面',
    'surface.review.label': 'Review',
    'surface.review.description': '证据与审查上下文',
    'surface.memory.label': 'Memory',
    'surface.memory.description': '站会与 AI 工作记忆',
    'surface.map.label': 'Session Map',
    'surface.map.description': '空间化 session 地图',
    'scope.personal': '个人',
    'scope.team': '团队',
    'scope.workspace': '工作区',
    'action.refresh': '刷新',
    'action.settings': '设置',
    'action.jumpBack': '跳回现场',
    'action.showInMap': '在 Session Map 中查看',
    'action.cancel': '取消',
    'action.save': '保存',
    'action.create': '创建',
    'action.delete': '删除',
    'cockpit.kicker': '个人 AI Cockpit',
    'cockpit.title': 'AI 工作进行中',
    'cockpit.subtitle': '以本机 session 为核心：状态、证据、风险和可跳回现场的接管点。',
    'cockpit.search': '搜索仓库、session、provider、状态或最近消息',
    'cockpit.loading': '正在加载本机 sessions...',
    'cockpit.sessions': '个 session',
    'cockpit.matching': '个匹配 session',
    'status.permissionRequired': '需要权限',
    'status.waitingForUser': '等待用户',
    'status.tooling': '工具执行',
    'status.thinking': '思考中',
    'status.compacting': '压缩上下文',
    'status.completed': '已完成',
    'status.dead': '失败',
    'time.none': '暂无活动',
    'time.justNow': '刚刚',
    'time.minutesAgo': '{count} 分钟前',
    'time.hoursAgo': '{count} 小时前',
    'time.daysAgo': '{count} 天前',
    'work.search': '搜索仓库、session、provider、状态或最近消息',
    'work.team.kicker': 'Phase 2 · 选择性同步',
    'work.team.title': '团队 AI Radar',
    'work.team.subtitle': '选择哪些本机 AI 工作对团队可见，默认不暴露完整 transcript。',
    'work.workrooms.kicker': 'Phase 3 · 接力',
    'work.workrooms.title': 'Workroom 与 Handoff',
    'work.workrooms.subtitle': '把一个或多个真实 session 放进临时救援、审查或接力工作面。',
    'work.review.kicker': 'Phase 4 · 证据',
    'work.review.title': 'Review Room',
    'work.review.subtitle': '先查看相关 AI session 的 PR 证据，再按需展开原始 transcript。',
    'work.memory.kicker': 'Phase 5 · 记忆',
    'work.memory.title': '团队记忆与审计',
    'work.memory.subtitle': '把 session 历史转成站会、保留策略和可审计的 AI 工作记忆。',
    'workmap.kicker': '空间化工作面',
    'workmap.title': 'Session Map',
    'workmap.subtitle': '用于排列实时 AI 工作、证据和接力上下文的空间化 session 地图。',
    'workmap.switching': '正在切换地图',
    'workmap.saving': '正在保存地图',
    'workmap.saved': '地图已保存',
    'map.new': '新建地图',
    'map.create': '创建地图',
    'map.delete': '删除地图',
    'map.rename': '重命名',
    'map.arrange': '排列',
    'map.default': '默认',
    'map.namePlaceholder': '地图名称',
    'map.createSubtitle': '命名地图，并选择它属于个人还是团队。',
    'map.deleteSubtitle': '这里只会移除地图容器。',
    'map.deleteBody': '这会移除地图布局和成员关系，不会删除 sessions。',
    'settings.title': '设置',
    'settings.subtitle': '主题、语言、同步、地图和 assistant 行为。',
    'settings.appearance': '外观',
    'settings.appearanceCaption': '所有工作面共用同一套主题和语言。',
    'settings.theme': '主题',
    'settings.theme.system': '跟随系统',
    'settings.theme.light': '亮色',
    'settings.theme.dark': '暗色',
    'settings.language': '语言',
    'settings.language.en': 'English',
    'settings.language.zh-CN': '中文',
  },
}

interface I18nContextValue {
  locale: Locale
  setLocale: (locale: Locale) => void
  t: (key: string, params?: Record<string, string | number>) => string
}

const I18nContext = createContext<I18nContextValue | null>(null)

function isLocale(value: string | null): value is Locale {
  return value === 'en' || value === 'zh-CN'
}

function detectLocale(): Locale {
  try {
    const stored = window.localStorage.getItem(LOCALE_STORAGE_KEY)
    if (isLocale(stored)) return stored
  } catch {
    // Ignore storage errors.
  }
  return navigator.language.toLowerCase().startsWith('zh') ? 'zh-CN' : 'en'
}

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLocaleState] = useState<Locale>(detectLocale)

  useEffect(() => {
    document.documentElement.lang = locale
  }, [locale])

  const setLocale = (next: Locale) => {
    setLocaleState(next)
    document.documentElement.lang = next
    try {
      window.localStorage.setItem(LOCALE_STORAGE_KEY, next)
    } catch {
      // Ignore storage errors; the in-memory choice still applies.
    }
  }

  const value = useMemo<I18nContextValue>(() => ({
    locale,
    setLocale,
    t: (key, params) => {
      const template = dictionaries[locale][key] ?? dictionaries.en[key] ?? key
      if (!params) return template
      return Object.entries(params).reduce(
        (text, [name, value]) => text.split(`{${name}}`).join(String(value)),
        template,
      )
    },
  }), [locale])

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>
}

export function useI18n(): I18nContextValue {
  const value = useContext(I18nContext)
  if (!value) throw new Error('useI18n must be used inside I18nProvider')
  return value
}
