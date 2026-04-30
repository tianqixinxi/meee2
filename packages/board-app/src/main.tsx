import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
// Excalidraw 0.18 不再把样式 inline 进 JS bundle —— 必须显式 import 这份 CSS，
// 否则 toolbar / icons / 选中框等所有 Excalidraw UI 全部失去样式。0.17 升 0.18
// 时漏了这步会看到工具图标巨大、卡片错位的画面。
import '@excalidraw/excalidraw/index.css'
import '@meee1/board-ui/SessionInspector.css'
import '@meee1/board-ui/TranscriptView.css'
import './styles.css'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)
