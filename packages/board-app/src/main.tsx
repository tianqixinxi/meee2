import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import { I18nProvider } from './i18n'
import { ThemeProvider } from './theme'
// Excalidraw 0.18 不再把样式 inline 进 JS bundle —— 必须显式 import 这份 CSS，
// 否则 toolbar / icons / 选中框等所有 Excalidraw UI 全部失去样式。0.17 升 0.18
// 时漏了这步会看到工具图标巨大、卡片错位的画面。
import '@excalidraw/excalidraw/index.css'
import '@meee1/board-ui/SessionInspector.css'
import '@meee1/board-ui/TranscriptView.css'
import './styles.css'

if (navigator.userAgent.includes('meee2-board-shell')) {
  document.documentElement.classList.add('meee2-board-shell')
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <ThemeProvider>
      <I18nProvider>
        <App />
      </I18nProvider>
    </ThemeProvider>
  </React.StrictMode>,
)
