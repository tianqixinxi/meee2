/**
 * IntegrationHealthCard (addendum §5) — CORE ledger card.
 *
 * Records the *observed health of bound integrations*: last credential probe
 * result, auth state, circuit-breaker status, and (optionally) the credential
 * actor identity. The probe ledger / circuit-breaker state is a later PR, so
 * this renders the configured integration scope plus the pending hint. No
 * fabricated health verdicts.
 *
 * Gated by `canvas.skills.v1` at the registry level.
 */

import type { IntegrationHealthConfig } from '../../../../types'
import type { MonitorCardProps } from '../cardTypes'
import { CardPending } from '../CardShell'

export function IntegrationHealthCard({ config }: MonitorCardProps<IntegrationHealthConfig>) {
  const ids = config.integrationIds ?? []
  return (
    <div className="monitor-integration-health">
      <div className="monitor-integration-health__scope">
        {ids.length > 0 ? `监控 ${ids.length} 个集成:${ids.join(', ')}` : '本画板全部已绑定集成'}
      </div>
      <CardPending
        what={
          config.showCredentialActor
            ? '集成健康(最近探测 / 鉴权状态 / 熔断器)与凭据主体身份'
            : '集成健康(最近探测 / 鉴权状态 / 熔断器)'
        }
      />
    </div>
  )
}
