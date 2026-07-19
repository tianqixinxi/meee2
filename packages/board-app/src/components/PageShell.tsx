// 页面骨架原语：统一「页眉（标题 + 副文案 + 工具区）+ 居中内容滚动区」。
// 收敛文档流页面（templates/artifacts/integrations/team）各写一套的容器范式；
// 数值（1080px 内容宽、34px 顶距、clamp 水平距）只在 styles.css .page-shell 一处定义。
import type { CSSProperties, ReactNode } from 'react'

interface PageShellProps {
  ariaLabel: string
  /** 眉题：标题上方的小号大写标签（可选）。 */
  kicker?: ReactNode
  title: ReactNode
  hint?: ReactNode
  /** 标题区下方的额外内容（如 artifacts 的 session filter chip）。 */
  headerExtra?: ReactNode
  tools?: ReactNode
  /** 覆盖默认内容宽度（1080px），数据表类页面可调宽。 */
  maxWidth?: number
  /** 额外挂在 section 上的类名（页面级逃生舱，能不用就不用）。 */
  className?: string
  children: ReactNode
}

export function PageShell({
  ariaLabel,
  kicker,
  title,
  hint,
  headerExtra,
  tools,
  maxWidth,
  className,
  children,
}: PageShellProps) {
  const innerStyle: CSSProperties | undefined = maxWidth ? { maxWidth } : undefined
  return (
    <section className={`page-shell${className ? ` ${className}` : ''}`} aria-label={ariaLabel}>
      <div className="page-shell__inner" style={innerStyle}>
        <header className="page-shell__header">
          <div className="page-shell__title-block">
            {kicker ? <span className="page-shell__kicker">{kicker}</span> : null}
            <h1>{title}</h1>
            {hint ? <p>{hint}</p> : null}
            {headerExtra}
          </div>
          {tools ? <div className="page-shell__tools">{tools}</div> : null}
        </header>
        {children}
      </div>
    </section>
  )
}
