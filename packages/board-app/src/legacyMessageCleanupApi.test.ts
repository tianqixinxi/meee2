import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanUpLegacyMessages, requestLegacyMessageCleanupToken } from './api'

describe('legacy message cleanup API', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('requests a scope-bound token before sending the distinct cleanup purpose', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        token: 'one-time-token',
        purpose: 'legacyMessageRetention',
        messageCount: 2,
        messageBytes: 512,
        issuedAt: '2026-07-10T00:00:00Z',
        expiresAt: '2026-07-10T00:02:00Z',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        ok: true,
        backupPath: '/tmp/test/backups/legacy-messages-1',
        removedCount: 2,
        reclaimedBytes: 512,
        failedCount: 0,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)

    const confirmation = await requestLegacyMessageCleanupToken()
    await cleanUpLegacyMessages({
      token: confirmation.token,
      purpose: confirmation.purpose,
    })

    expect(fetchMock.mock.calls[0][0]).toBe('/api/system/legacy-message-cleanup/token')
    expect(fetchMock.mock.calls[0][1]).toMatchObject({ method: 'POST' })
    expect(fetchMock.mock.calls[1][0]).toBe('/api/system/legacy-message-cleanup')
    expect(JSON.parse(String(fetchMock.mock.calls[1][1]?.body))).toEqual({
      token: 'one-time-token',
      purpose: 'legacyMessageRetention',
    })
  })
})
