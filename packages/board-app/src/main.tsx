import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import { I18nProvider } from './lib/i18n'
import { ThemeProvider } from './lib/theme'
import { installControlPlaneFetch } from './controlPlane'
import { isHostedLlmProvider, readLlmSettings, writeLlmSettings } from './lib/llmSettings'
import '@fontsource-variable/inter'
import '@fontsource-variable/jetbrains-mono'
import './styles.css'

installControlPlaneFetch()
migrateLegacyAssistantSecret()

function migrateLegacyAssistantSecret(): void {
  const settings = readLlmSettings()
  const apiKey = settings.apiKey.trim()
  if (!apiKey || !isHostedLlmProvider(settings.provider)) return
  void fetch('/api/assistant/secret', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ provider: settings.provider, apiKey }),
  }).then((response) => {
    if (response.ok) writeLlmSettings({ ...settings, apiKey: '' })
  }).catch(() => {
    // Keep the legacy value until Keychain confirms the migration.
  })
}

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
