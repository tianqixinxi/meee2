import { useEffect, useState, useCallback } from 'react'
import {
  checkForVersionUpdate,
  checkUpdateInBackground,
  fetchVersion,
  installAppUpdate,
  type VersionInfo,
} from '../api'
import { Tooltip } from './Tooltip'

/**
 * Codex-style "Update" pill —— sidebar header 右上角(traffic-light 旁边),
 * 只在 hasUpdate=true 时出现。点一下走 Sparkle 安装流程:
 *
 *   1. 后台 (SUAutomaticallyUpdate=YES + 24h 调度) 已经下载 + 验签好新版
 *   2. 点 pill → POST /api/update/install → AppDelegate 调
 *      SPUStandardUpdaterController.checkForUpdates(_:)
 *   3. Sparkle 跳过下载步,弹 "Install and Relaunch" 一键确认框
 *   4. 用户点一下 → app 立即 apply + relaunch 到新版本
 *
 * 没新版时整个组件不渲染任何东西,sidebar header 右侧空白。
 *
 * 轮询间隔:8 分钟。频率低是因为后端 VersionChecker 自己每 6h 才刷一次 cache,
 * webui 这边主要为了"启动后立刻看到状态" + "几分钟内 catch 上 cache 刷新"。
 */
const POLL_INTERVAL_MS = 8 * 60 * 1000

/**
 * Dev 模式 = Vite dev server (import.meta.env.DEV) **或** URL 带 ?devUpdate=1
 * **或** localStorage 设了 meee2.devUpdate=1。后两条让生产 build 也能 ad-hoc
 * 打开 update 调试面板("Stage" / 强制 re-check 等),不必跑 vite dev。
 *
 * dev 模式额外多渲染:
 *   - hasUpdate=false 时:"Check" pill(强制 re-fetch appcast.xml + 触发后台下载)
 *   - hasUpdate=true 时:"Stage" pill 跟 "Update" pill 并排(单独触发预下载用)
 */
const IS_DEV = (() => {
  // Vite dev server
  if ((import.meta as { env?: { DEV?: boolean } }).env?.DEV === true) return true
  if (typeof window !== 'undefined') {
    // ?devUpdate=1 一次性,刷新就没了
    const params = new URLSearchParams(window.location.search)
    if (params.get('devUpdate') === '1') return true
    // localStorage 持久,清掉 key 就回到生产模式
    try {
      if (window.localStorage.getItem('meee2.devUpdate') === '1') return true
    } catch { /* private mode */ }
  }
  return false
})()

export function UpdatePill() {
  const [info, setInfo] = useState<VersionInfo | null>(null)
  const [installing, setInstalling] = useState(false)
  const [checking, setChecking] = useState(false)
  // dev-only "Stage" button —— 记录最后一次触发后台下载的时间。Sparkle 没
  // 暴露"已 stage"的 API,只能用经过时间近似:点完后 30s 内显示
  // "Staging…",30s 后显示 "Staged Hh:Mm:Ss" 让你判断"现在点 Update 应该秒
  // 重启了"。
  const [stagedAt, setStagedAt] = useState<number | null>(null)
  const [staging, setStaging] = useState(false)

  const refresh = useCallback(async () => {
    try {
      const v = await fetchVersion()
      setInfo(v)
    } catch {
      // 静默失败 —— /api/version 在更老的 board server 上 404,
      // 这种情况就当作"没更新"处理,什么都别渲染。
    }
  }, [])

  useEffect(() => {
    refresh()
    const id = window.setInterval(refresh, POLL_INTERVAL_MS)
    // 切回 tab 时也刷一次,Vite HMR / 用户离开很久回来时立即同步状态。
    const onVisible = () => { if (document.visibilityState === 'visible') refresh() }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      window.clearInterval(id)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [refresh])

  /**
   * 手动 Check 触发两件事并行:
   *
   * 1. POST /api/version/check —— 强制后端 VersionChecker 重新拉 appcast.xml,
   *    立即更新 webui 显示的 latest/hasUpdate。
   * 2. POST /api/update/check-in-background —— silent 走 Sparkle 完整 cycle:
   *    appcast → 下载 DMG → 验签 → stage。让你之后点 Update pill 时是
   *    "立刻 Install and Relaunch"(没下载等待),复刻生产 24h 调度后的体验。
   *
   * 没 #2 的话,dev 下点 Update 会真去下载,要等几秒到几十秒,看不出
   * "预下载完了点击秒装" 那个效果。
   */
  const triggerCheck = async () => {
    if (checking) return
    setChecking(true)
    try {
      // 后台下载是 fire-and-forget;不 await 它,否则 UI 卡到 Sparkle 下完才解锁
      void checkUpdateInBackground().catch(() => {})
      const v = await checkForVersionUpdate()
      setInfo(v)
    } catch {
      // ignore
    } finally {
      setChecking(false)
    }
  }

  const onInstallClick = async (e: React.MouseEvent) => {
    if (installing) return
    // alt+click = 隐藏的"强制重新检查"快捷键(prod 下用,dev 有显式 Check pill)
    if (e.altKey) {
      void triggerCheck()
      return
    }
    setInstalling(true)
    try {
      await installAppUpdate()
      window.setTimeout(() => setInstalling(false), 5000)
    } catch {
      setInstalling(false)
    }
  }

  if (!info) return null
  // **生产模式 codex-style**:只在 Sparkle 已经后台下完 + staged 之后才渲染。
  // hasUpdate=true 但还没 staged → 用户看不到 pill,直到下载完成。
  // dev 模式覆盖这条 gate,让你能测 hasUpdate=true 但还没下载的"现场下"路径。
  if (!IS_DEV && !info.isStaged) return null
  if (!info.hasUpdate && !IS_DEV) return null

  if (info.hasUpdate && info.latest) {
    const tooltipLabel = `Update available: ${info.latest} (current ${info.current})`
      + (IS_DEV ? '\nAlt-click to force re-check appcast' : '')

    // Dev-only stage button —— 触发 Sparkle 后台 silent 下载,不装。点完
    // 等 ~30s 让 DMG 下完 + 验签,再点 Update 应该是"秒重启"(没下载等待)。
    const triggerStage = async () => {
      if (staging) return
      setStaging(true)
      setStagedAt(null)
      try {
        await checkUpdateInBackground()
        // Sparkle 没有"download done" 回调到 webui,只能用时间近似:30s 后
        // 标记 staged,提示"现在点 Update 应该是 instant"。
        window.setTimeout(() => {
          setStaging(false)
          setStagedAt(Date.now())
        }, 30000)
      } catch {
        setStaging(false)
      }
    }

    const stageLabel = staging
      ? 'Staging…'
      : stagedAt
        ? `Staged ${new Date(stagedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}`
        : 'Stage'

    return (
      <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
        {IS_DEV && (
          <Tooltip label={`[dev] Trigger Sparkle background download (silent). After ~30s the DMG is staged + verified; clicking Update then is an instant relaunch (no download wait). Clears on app restart.`}>
            <button
              className={'update-pill update-pill--dev' + (staging ? ' update-pill--installing' : '')}
              onClick={triggerStage}
              disabled={staging}
              aria-label="Stage update in background"
            >
              {stageLabel}
            </button>
          </Tooltip>
        )}
        <Tooltip label={tooltipLabel}>
          <button
            className={'update-pill' + (installing ? ' update-pill--installing' : '')}
            onClick={onInstallClick}
            disabled={installing}
            aria-label={`Install update ${info.latest}`}
          >
            {installing ? 'Installing…' : 'Update'}
          </button>
        </Tooltip>
      </div>
    )
  }

  // Dev-only:没新版时显示 "Check" pill,点一下强制重拉 appcast。
  // 生产环境永远走不到这里(上面 early return 兜了)。
  const checkLabel = checking
    ? 'Checking…'
    : info.lastError
      ? 'Check (last error)'
      : info.latest
        ? `Up-to-date (${info.current})`
        : 'Check'
  return (
    <Tooltip label={`[dev] Force refresh appcast.xml. Current: ${info.current}, latest cache: ${info.latest ?? '—'}${info.lastError ? `, error: ${info.lastError}` : ''}`}>
      <button
        className={'update-pill update-pill--dev' + (checking ? ' update-pill--installing' : '')}
        onClick={triggerCheck}
        disabled={checking}
        aria-label="Force check for updates"
      >
        {checkLabel}
      </button>
    </Tooltip>
  )
}
