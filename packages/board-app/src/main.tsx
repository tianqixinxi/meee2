import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import { I18nProvider } from './lib/i18n'
import { ThemeProvider } from './lib/theme'
import '@xyflow/react/dist/style.css'
import './styles.css'

if (typeof navigator !== 'undefined' && navigator.userAgent.includes('meee2-board-shell')) {
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
