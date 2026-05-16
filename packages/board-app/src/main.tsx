import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import '@xyflow/react/dist/style.css'
import './styles.css'

if (navigator.userAgent.includes('meee2-board-shell')) {
  document.documentElement.classList.add('meee2-board-shell')
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)
