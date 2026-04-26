// Per-session 卡片动效 / 视觉配置。独立于卡片 TSX 模板源码 —— 模板只负责
// "数据怎么排"，这里负责"活起来时候怎么抖、什么颜色、呼吸多快"。
//
// 模板通过 session._animations 读取（CardHost 注入）。模板可以忽略它继续
// 写死，也可以 fallback 到 config。典型用法：
//
//   const halo = session._animations?.liveHalo
//   const liveColor = halo?.color ?? '#22C55E'
//   const speed = halo?.speed ?? 3.2      // seconds per breathe cycle
//   box-shadow: `0 0 ${halo?.glowPx ?? 14}px ${liveColor}33`
//
// 存储：localStorage（per-session），持久化后端是将来的事 —— 先用 v1 格式
// 在浏览器本地 iterate，定型后再搬到 ~/.meee2/card-animations/<sid>.json。

export interface CardAnimations {
  /** Live 状态的光晕 / 边框发光 */
  liveHalo?: {
    /** 色值 hex；默认 '#22C55E'（绿）。支持任意 CSS color */
    color?: string
    /** 一次呼吸周期的秒数；0 表示关闭呼吸 */
    speedSeconds?: number
    /** 光晕模糊半径（px） */
    glowPx?: number
    /** 强度等级：subtle / normal / loud —— 控制 box-shadow 的透明度叠加 */
    intensity?: 'subtle' | 'normal' | 'loud'
  }
  /** 状态圆点脉冲（permissionRequired / urgent 用） */
  statusDotPulse?: {
    enabled?: boolean
    rateSeconds?: number
  }
  /** 新 card 刚出现在画板上的 fade-in（操作反馈） */
  arrivalFadeIn?: {
    enabled?: boolean
    durationMs?: number
  }
}

/** 默认 animations —— 跟 DEFAULT_TEMPLATE 的现状对齐，改这里不碰模板源码 */
export const DEFAULT_ANIMATIONS: CardAnimations = {
  liveHalo: {
    color: '#22C55E',
    speedSeconds: 3.2,
    glowPx: 14,
    intensity: 'normal',
  },
  statusDotPulse: {
    enabled: true,
    rateSeconds: 1.6,
  },
  arrivalFadeIn: {
    enabled: true,
    durationMs: 240,
  },
}

const STORAGE_KEY = 'meee2.card-animations.v1'

interface StoredMap {
  /** key = sessionId 或 '__default__'；后者是画板全局 fallback */
  [k: string]: CardAnimations
}

function loadAll(): StoredMap {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return {}
    const j = JSON.parse(raw)
    if (j && typeof j === 'object') return j as StoredMap
  } catch { /* ignore */ }
  return {}
}

function saveAll(m: StoredMap): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(m))
  } catch { /* quota */ }
}

/**
 * 查询 session 对应的动效配置。
 * 解析顺序：session-specific → global default → bundled DEFAULT_ANIMATIONS。
 * 返回的对象是浅合并后的结果，保证每个字段都有值。
 */
export function getAnimationsFor(sessionId: string): CardAnimations {
  const all = loadAll()
  const sess = all[sessionId] ?? {}
  const glob = all.__default__ ?? {}
  return mergeAnimations(DEFAULT_ANIMATIONS, mergeAnimations(glob, sess))
}

/** 写入 session-specific 动效。传 null 清掉该 session 的 override。 */
export function setAnimationsFor(sessionId: string, a: CardAnimations | null): void {
  const all = loadAll()
  if (a == null) {
    delete all[sessionId]
  } else {
    all[sessionId] = a
  }
  saveAll(all)
}

/** 写入全局 default（所有 session 的 fallback）。 */
export function setGlobalAnimations(a: CardAnimations | null): void {
  setAnimationsFor('__default__', a)
}

/** 浅合并两个 CardAnimations（按 section 合并，每个 section 内浅合并） */
function mergeAnimations(base: CardAnimations, over: CardAnimations): CardAnimations {
  return {
    liveHalo: { ...(base.liveHalo ?? {}), ...(over.liveHalo ?? {}) },
    statusDotPulse: { ...(base.statusDotPulse ?? {}), ...(over.statusDotPulse ?? {}) },
    arrivalFadeIn: { ...(base.arrivalFadeIn ?? {}), ...(over.arrivalFadeIn ?? {}) },
  }
}
