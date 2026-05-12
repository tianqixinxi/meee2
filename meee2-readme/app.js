const THEME_KEY = 'meee2-readme.theme.v1'
const LOCALE_KEY = 'meee2-readme.locale.v1'

const translations = {
  'zh-CN': {
    'nav.architecture': '架构',
    'nav.dataFlow': '数据流',
    'nav.model': '模型',
    'nav.sync': '同步',
    'nav.feishu': '飞书',
    'nav.usecases': 'Use cases',
    'nav.roadmap': 'Roadmap',
    'hero.eyebrow': 'Session-first · Local-first · Selective-sync',
    'hero.title': '让工程团队看见、控制并协作处理本机正在运行的 AI 编程工作。',
    'hero.lead': 'meee2 不做通用白板，也不替代 Jira / Linear。它把 Claude Code、Codex、Cursor、OpenClaw 等本地 AI session 变成可观察、可同步、可接力、可审查的真实工作执行层。',
    'hero.primary': '查看架构',
    'hero.secondary': '查看隐私边界',
    'surfaces.eyebrow': 'Product UI',
    'surfaces.title': '六个入口统一成 Work Surfaces',
    'surfaces.copy': '前五个是结构化工作面，Session Map 是空间化 session 地图。它们都读取 Session Graph，并共享同一套主题、语言和色彩体系。',
    'surfaces.cockpit': '个人工作面',
    'surfaces.team': '团队态势工作面',
    'surfaces.workroom': '接力协作工作面',
    'surfaces.review': '证据审查工作面',
    'surfaces.memory': '团队记忆工作面',
    'surfaces.map': '空间化 session 地图',
  },
  en: {
    'nav.architecture': 'Architecture',
    'nav.dataFlow': 'Data flow',
    'nav.model': 'Model',
    'nav.sync': 'Sync',
    'nav.feishu': 'Feishu',
    'nav.usecases': 'Use cases',
    'nav.roadmap': 'Roadmap',
    'hero.eyebrow': 'Session-first · Local-first · Selective-sync',
    'hero.title': 'Make local AI coding work visible, controllable, and handoff-ready for engineering teams.',
    'hero.lead': 'meee2 is not a generic whiteboard or a Jira / Linear replacement. It turns local Claude Code, Codex, Cursor, and OpenClaw sessions into an observable execution layer with status, evidence, risk, sync policy, and handoff points.',
    'hero.primary': 'View architecture',
    'hero.secondary': 'View privacy boundary',
    'surfaces.eyebrow': 'Product UI',
    'surfaces.title': 'Six entries become one Work Surfaces system',
    'surfaces.copy': 'The first five entries are structured work surfaces. Session Map is the spatial session map. All of them read from Session Graph and share one theme, language, and color system.',
    'surfaces.cockpit': 'Personal work surface',
    'surfaces.team': 'Team radar surface',
    'surfaces.workroom': 'Handoff collaboration surface',
    'surfaces.review': 'Evidence review surface',
    'surfaces.memory': 'Team memory surface',
    'surfaces.map': 'Spatial session map',
  },
}

const themeToggle = document.querySelector('[data-theme-toggle]')
const localeToggle = document.querySelector('[data-locale-toggle]')

function detectTheme() {
  const stored = localStorage.getItem(THEME_KEY)
  if (stored === 'light' || stored === 'dark') return stored
  return window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'
}

function setTheme(theme) {
  document.documentElement.dataset.theme = theme
  localStorage.setItem(THEME_KEY, theme)
  if (themeToggle) themeToggle.textContent = theme === 'light' ? 'Dark' : 'Light'
}

function detectLocale() {
  const stored = localStorage.getItem(LOCALE_KEY)
  if (stored === 'en' || stored === 'zh-CN') return stored
  return navigator.language.toLowerCase().startsWith('zh') ? 'zh-CN' : 'en'
}

function setLocale(locale) {
  const dict = translations[locale] ?? translations.en
  document.documentElement.lang = locale
  localStorage.setItem(LOCALE_KEY, locale)
  document.querySelectorAll('[data-i18n]').forEach((node) => {
    const key = node.dataset.i18n
    if (dict[key]) node.textContent = dict[key]
  })
  if (localeToggle) localeToggle.textContent = locale === 'zh-CN' ? 'EN' : '中'
}

setTheme(detectTheme())
setLocale(detectLocale())

themeToggle?.addEventListener('click', () => {
  setTheme(document.documentElement.dataset.theme === 'light' ? 'dark' : 'light')
})

localeToggle?.addEventListener('click', () => {
  setLocale(document.documentElement.lang === 'zh-CN' ? 'en' : 'zh-CN')
})

const layerButtons = document.querySelectorAll('.layer-button')
const flowNodes = document.querySelectorAll('.flow-node')

function setActiveLayer(layer) {
  layerButtons.forEach((button) => {
    button.classList.toggle('active', button.dataset.layer === layer)
  })
  flowNodes.forEach((node) => {
    node.classList.toggle('highlight', node.dataset.layerNode === layer)
  })
}

layerButtons.forEach((button) => {
  button.addEventListener('click', () => setActiveLayer(button.dataset.layer))
})
setActiveLayer('tools')

const policyContent = {
  private: {
    title: 'Private',
    copy: '只在本机，不上传到团队或飞书。',
    payload: {
      uploads: [],
    },
  },
  metadata: {
    title: 'Metadata only',
    copy: '团队只看到 owner、repo、branch、provider、status、blocker；不包含 recent messages 或 transcript。',
    payload: {
      sessionId: 'codex-abc123',
      owner: 'local-user',
      provider: 'Codex',
      repo: 'meee2',
      branch: 'codex/personal-ai-cockpit',
      status: 'blocked',
      blocker: 'permission required',
    },
  },
  summary: {
    title: 'Summary',
    copy: '在 metadata 基础上同步 current step、recap 和风险摘要，但仍不上传 transcript。',
    payload: {
      sessionId: 'codex-abc123',
      repo: 'meee2',
      status: 'running',
      currentStep: 'Implement selective sync contract',
      recentSummary: 'Pusher now filters session payloads by policy.',
      risks: [{ type: 'sync_policy', severity: 'medium' }],
    },
  },
  recentContext: {
    title: 'Recent context',
    copy: '允许同步最近几条消息预览，适合需要轻量协作但不需要完整审计的场景。',
    payload: {
      sessionId: 'codex-abc123',
      currentStep: 'Create Feishu handoff doc',
      recentMessages: [
        { role: 'user', text: '继续做完 selective sync' },
        { role: 'assistant', text: '已将 syncPolicy 接入 SessionDTO' },
      ],
    },
  },
  fullTranscript: {
    title: 'Full transcript',
    copy: '完整 transcript 必须显式确认，适合审计或强协作场景。',
    payload: {
      sessionId: 'codex-abc123',
      fullTranscriptAllowed: true,
      transcriptGovernance: 'explicit opt-in required',
    },
  },
  artifactsOnly: {
    title: 'Artifacts only',
    copy: '只同步 PR、diff、test、deploy 等证据，适合安全敏感团队。',
    payload: {
      sessionId: 'codex-abc123',
      artifacts: [
        { type: 'test', title: 'swift test', status: 'passed' },
        { type: 'doc', title: 'Feishu handoff doc', status: 'created' },
      ],
    },
  },
}

const policyTabs = document.querySelectorAll('.policy-tab')
const policyTitle = document.getElementById('policy-title')
const policyCopy = document.getElementById('policy-copy')
const policyPayload = document.getElementById('policy-payload')

function setPolicy(policy) {
  const item = policyContent[policy] ?? policyContent.private
  policyTabs.forEach((tab) => tab.classList.toggle('active', tab.dataset.policy === policy))
  policyTitle.textContent = item.title
  policyCopy.textContent = item.copy
  policyPayload.textContent = JSON.stringify(item.payload, null, 2)
}

policyTabs.forEach((tab) => {
  tab.addEventListener('click', () => setPolicy(tab.dataset.policy))
})
setPolicy('private')
