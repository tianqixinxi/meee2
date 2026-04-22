// Babel Standalone wrapper. Transpiles user-authored TSX/JSX into plain JS the
// sandboxed iframe can evaluate. Loaded once in the parent bundle — the
// iframes only receive the compiled string.

import * as Babel from '@babel/standalone'

export interface CompileResult {
  code: string
  error?: string
}

/**
 * Compile a single-file TSX template. The template should `export default` a
 * React component function. We run Babel with the typescript + react classic
 * presets so the output references `React.createElement` at the top level (no
 * need for a runtime auto-import).
 */
export function compileCardSource(source: string): CompileResult {
  try {
    const out = (Babel as any).transform(source, {
      presets: [
        ['typescript', { allExtensions: true, isTSX: true, onlyRemoveTypeImports: true }],
        ['react', { runtime: 'classic' }],
      ],
      // ES module → CommonJS。不加这个，`export default Foo` 会原样出现在
      // 编译结果里，iframe 的 `new Function(code)` 直接语法错误
      // （"Unexpected token 'export'"）。CommonJS 变换把它转成
      // `exports.default = Foo`，iframe 端从 module.exports.default 取组件。
      plugins: ['transform-modules-commonjs'],
      filename: 'card.tsx',
      sourceType: 'module',
    })
    return { code: (out && out.code) || '' }
  } catch (e) {
    return { code: '', error: (e as Error).message }
  }
}
