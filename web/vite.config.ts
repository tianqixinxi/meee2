import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// 注意 NODE_ENV：Vite 会根据 build mode 自动设置 process.env.NODE_ENV
// (dev→development, build→production)。之前我们手动 define 成 'development' 会
// 污染 prod 构建 —— 让 React 的 dev-only CJS 模块 (react-jsx-runtime.development.js)
// 被打包进 ESM bundle，浏览器里因为没有 `exports` 这个全局而直接抛
// "exports is not defined"。所以 NODE_ENV 不要自己 define。
export default defineConfig(({ mode }) => ({
  plugins: [react()],
  base: './',
  define: {
    // Excalidraw 运行时读 process.env.IS_PREACT；两种 mode 都需要静态替换，
    // 否则 dev 下浏览器抛 "process is not defined"、prod 下 tree-shake 依赖分支。
    'process.env.IS_PREACT': JSON.stringify('false'),
  },
  build: {
    outDir: '../Sources/Board/WebDist',
    emptyOutDir: true,
    sourcemap: false,
    chunkSizeWarningLimit: 2000,
  },
  server: {
    port: 5173,
    proxy: {
      '/api/events': { target: 'ws://localhost:9876', ws: true },
      '/api': { target: 'http://localhost:9876', changeOrigin: true },
    },
  },
  // Silence unused-param warning in dev builds.
  ...(mode ? {} : {}),
}))
