import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

const boardApiTarget =
  process.env.MEEE2_BOARD_API_URL ??
  `http://127.0.0.1:${process.env.MEEE2_BOARD_PORT ?? '9876'}`
const boardWsTarget = boardApiTarget.replace(/^http/, 'ws')

// 注意 NODE_ENV：Vite 会根据 build mode 自动设置 process.env.NODE_ENV
// (dev→development, build→production)。之前我们手动 define 成 'development' 会
// 污染 prod 构建 —— 让 React 的 dev-only CJS 模块 (react-jsx-runtime.development.js)
// 被打包进 ESM bundle，浏览器里因为没有 `exports` 这个全局而直接抛
// "exports is not defined"。所以 NODE_ENV 不要自己 define。
export default defineConfig(({ mode }) => ({
  plugins: [react()],
  base: './',
  build: {
    outDir: '../../Sources/Board/WebDist',
    emptyOutDir: true,
    sourcemap: false,
    chunkSizeWarningLimit: 500,
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (!id.includes('/node_modules/')) return undefined
          if (id.includes('/@xyflow/')) return 'vendor-xyflow'
          if (
            id.includes('/react/') ||
            id.includes('/react-dom/') ||
            id.includes('/scheduler/')
          ) return 'vendor-react'
          if (
            id.includes('/react-markdown/') ||
            id.includes('/remark-') ||
            id.includes('/rehype-') ||
            id.includes('/unified@') ||
            id.includes('/micromark') ||
            id.includes('/mdast-') ||
            id.includes('/hast-')
          ) return 'vendor-markdown'
          return undefined
        },
      },
    },
  },
  server: {
    host: '127.0.0.1',
    port: 5002,
    strictPort: true,
    proxy: {
      '/api/events': { target: boardWsTarget, ws: true },
      '/api': { target: boardApiTarget, changeOrigin: true },
    },
  },
  // Silence unused-param warning in dev builds.
  ...(mode ? {} : {}),
}))
