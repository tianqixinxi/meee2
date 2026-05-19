import { KeyRound, ShieldCheck } from 'lucide-react'
import type { BoardState } from '../types'
import { AgentIntegrationMatrix } from './AgentIntegrationMatrix'

interface Props {
  state: BoardState | null
}

/**
 * Integrations 页 —— 整合后的单一入口:
 *  · 顶部:agent × integration 接入体检矩阵 + 缺口的 Runbook 引导
 *  · 矩阵里 connected 的 github/lark 行可展开「Browse」浏览外部条目
 *
 * 老的 IntegrationStatus / IntegrationCardView / fetchIntegrationStatus
 * 流程已收掉(被 AgentIntegrationMatrix 覆盖)。`Props.state` 暂留以保持
 * App.tsx 的调用签名,本组件未使用。
 */
export function IntegrationsView(_props: Props) {
  return (
    <section className="integrations-view" aria-label="Integrations">
      <header className="integrations-view__header">
        <div>
          <span>Integrations</span>
          <h1>External systems</h1>
        </div>
        <div className="integrations-view__summary">
          <ShieldCheck size={14} aria-hidden />
          Explicit binding only
        </div>
      </header>

      <AgentIntegrationMatrix />

      <section className="integrations-view__contract">
        <div>
          <KeyRound size={15} aria-hidden />
          <strong>Runtime boundary</strong>
        </div>
        <p>
          Integrations are not new Planner node types. They are readable output
          sources for planner nodes. To use one in a workflow, open a node and
          attach the chosen item as evidence — existing sessions are never
          auto-linked.
        </p>
      </section>
    </section>
  )
}
