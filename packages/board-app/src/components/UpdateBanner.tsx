import { useCallback, useEffect, useState } from 'react'
import { fetchVersion, installAppUpdate, type VersionInfo } from '../api'
import { useI18n } from '../lib/i18n'

/**
 * 左下角"有新版本"提示 banner。
 *
 * 跟 {@link UpdatePill}(右上角、只在 staged 之后才冒头)互补:banner 的目标是
 * **主动、显眼地告诉用户有更新**,所以只要后端 VersionChecker 报 hasUpdate=true
 * 就滑出来,不等 Sparkle 把包下完。
 *
 *   - 后台仍然是 Sparkle 静默轮询(1h)+ 启动主动 check,检测到就下载/验签/stage。
 *   - 这个 banner 只读 /api/version 的状态,点 "更新并重启" → POST /api/update/install:
 *       · 已 staged → AppDelegate 确认 pending install,几秒内 relaunch 到新版。
 *       · 没 staged → Sparkle 现场下载并安装(会多等一会)。hint 文案会区分两者。
 *   - 点 × 忽略 → 记住当前 latest 版本号,这个版本不再打扰;出更高版本再提示。
 *
 * Web 端不需要 push;每 8 分钟本地轮询 /api/version,tab 回前台时也立即刷新
 * (跟 UpdatePill 一致)。
 *
 * 文案故意内联在本组件,不进 lib/i18n.tsx:banner 是自包含浮层,且 i18n.tsx
 * 经常被其它分支并发编辑,内联可避免共享文件的 write-over。
 */
const POLL_INTERVAL_MS = 8 * 60 * 1000
const DISMISS_KEY = 'meee2.updateBanner.dismissedVersion'
const IS_DEBUG_BUILD = (import.meta as { env?: { DEV?: boolean } }).env?.DEV === true

const COPY = {
  en: {
    title: 'A new version is available',
    stagedHint: 'Downloaded and ready — restart to update.',
    downloadHint: 'Click to download and install the latest version.',
    update: 'Update & Restart',
    updating: 'Updating…',
    dismiss: 'Dismiss',
  },
  'zh-CN': {
    title: '有新版本可用',
    stagedHint: '已下载就绪 —— 重启即可更新。',
    downloadHint: '点击下载并安装最新版本。',
    update: '更新并重启',
    updating: '更新中…',
    dismiss: '忽略',
  },
} as const

export function UpdateBanner() {
  const { locale } = useI18n()
  const copy = COPY[locale] ?? COPY.en
  const [info, setInfo] = useState<VersionInfo | null>(null)
  const [installing, setInstalling] = useState(false)
  const [dismissedVersion, setDismissedVersion] = useState<string | null>(() => {
    try {
      return window.localStorage.getItem(DISMISS_KEY)
    } catch {
      return null
    }
  })

  const refresh = useCallback(async () => {
    try {
      setInfo(await fetchVersion())
    } catch {
      // /api/version 在更老的 board server 上 404 —— 当作"没更新",什么都不渲染。
    }
  }, [])

  useEffect(() => {
    if (IS_DEBUG_BUILD) return undefined
    refresh()
    const id = window.setInterval(refresh, POLL_INTERVAL_MS)
    // 切回 tab 时也刷一次:用户离开很久回来时立即同步状态。
    const onVisible = () => {
      if (document.visibilityState === 'visible') refresh()
    }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      window.clearInterval(id)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [refresh])

  const onUpdate = async () => {
    if (installing) return
    setInstalling(true)
    try {
      await installAppUpdate()
      // staged 的话 app 几秒内 relaunch(webview 整个重载,banner 自然消失);
      // 没 staged 走现场下载,8s 后复位让用户能重试。
      window.setTimeout(() => setInstalling(false), 8000)
    } catch {
      setInstalling(false)
    }
  }

  const onDismiss = () => {
    const v = info?.latest
    if (!v) return
    try {
      window.localStorage.setItem(DISMISS_KEY, v)
    } catch {
      // private mode —— 记不住就这次会话内不再用 state 兜一下。
    }
    setDismissedVersion(v)
  }

  if (IS_DEBUG_BUILD || info?.debugBuild || !info || !info.hasUpdate || !info.latest) return null
  // 用户已忽略过这个版本 → 不再打扰,直到远端出更高版本(latest 变了)。
  if (dismissedVersion && dismissedVersion === info.latest) return null

  return (
    <div className="update-banner" role="status" aria-live="polite">
      <button
        type="button"
        className="update-banner__close"
        onClick={onDismiss}
        aria-label={copy.dismiss}
        title={copy.dismiss}
      >
        ×
      </button>
      <div className="update-banner__head">
        <span className="update-banner__icon" aria-hidden="true">
          <svg
            width="15"
            height="15"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2.2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <path d="M12 19V5M5 12l7-7 7 7" />
          </svg>
        </span>
        <span className="update-banner__title">{copy.title}</span>
      </div>
      <div className="update-banner__hint">
        {info.isStaged ? copy.stagedHint : copy.downloadHint}
      </div>
      <div className="update-banner__foot">
        <span className="update-banner__version">
          {info.current} → {info.latest}
        </span>
        <button
          type="button"
          className={'update-banner__cta' + (installing ? ' is-busy' : '')}
          onClick={onUpdate}
          disabled={installing}
        >
          {installing ? copy.updating : copy.update}
        </button>
      </div>
    </div>
  )
}
