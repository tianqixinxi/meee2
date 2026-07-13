import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  artifactForReference,
  artifactPositionLabel,
  compactLabel,
  dedupeStrings,
  relativeTimeLabel,
  truncateMessageText,
} from './NodeInspectorModal'
import type { PlannerArtifact } from '../../types'

function artifact(overrides: Partial<PlannerArtifact> = {}): PlannerArtifact {
  return {
    id: 'a1',
    canvasId: 'c1',
    nodeId: 'n1',
    kind: 'generic',
    title: 'Some Artifact',
    reference: 'repo://docs/prd/spec.md',
    status: 'attached',
    createdAt: new Date('2026-05-01T00:00:00Z').toISOString(),
    ...overrides,
  }
}

describe('relativeTimeLabel', () => {
  // Freeze "now" so the bucket boundaries are deterministic.
  const NOW = new Date('2026-05-30T12:00:00Z').getTime()
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(NOW)
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('returns 刚刚 for a timestamp within the last minute', () => {
    expect(relativeTimeLabel(new Date(NOW - 30_000).toISOString())).toBe('刚刚')
  })

  it('returns 刚刚 for a future timestamp', () => {
    expect(relativeTimeLabel(new Date(NOW + 60_000).toISOString())).toBe('刚刚')
  })

  it('returns N 分钟前 between 1 and 59 minutes', () => {
    expect(relativeTimeLabel(new Date(NOW - 5 * 60_000).toISOString())).toBe('5 分钟前')
    expect(relativeTimeLabel(new Date(NOW - 59 * 60_000).toISOString())).toBe('59 分钟前')
  })

  it('returns N 小时前 between 1 and 23 hours', () => {
    expect(relativeTimeLabel(new Date(NOW - 3 * 3_600_000).toISOString())).toBe('3 小时前')
    expect(relativeTimeLabel(new Date(NOW - 23 * 3_600_000).toISOString())).toBe('23 小时前')
  })

  it('returns N 天前 at 24 hours and beyond', () => {
    expect(relativeTimeLabel(new Date(NOW - 24 * 3_600_000).toISOString())).toBe('1 天前')
    expect(relativeTimeLabel(new Date(NOW - 10 * 24 * 3_600_000).toISOString())).toBe('10 天前')
  })

  it('returns empty string for an unparseable timestamp', () => {
    expect(relativeTimeLabel('not-a-date')).toBe('')
  })
})

describe('truncateMessageText', () => {
  it('collapses runs of whitespace into single spaces and trims', () => {
    expect(truncateMessageText('  hello\n\tworld   foo  ')).toBe('hello world foo')
  })

  it('returns text unchanged when at or under max length', () => {
    expect(truncateMessageText('short', 80)).toBe('short')
  })

  it('truncates and appends an ellipsis past max length', () => {
    const result = truncateMessageText('abcdefghij', 5)
    expect(result).toBe('abcde…')
  })

  it('trims trailing whitespace before the ellipsis', () => {
    // Whitespace is collapsed first ("a    bcdef" -> "a bcdef"), then sliced:
    // slice(0,5) -> "a bcd" -> trimEnd -> "a bcd".
    expect(truncateMessageText('a    bcdef', 5)).toBe('a bcd…')
    // A boundary that lands on a space gets trimmed back.
    expect(truncateMessageText('ab cdef', 3)).toBe('ab…')
  })
})

describe('artifactForReference', () => {
  it('matches by reference case-insensitively, ignoring surrounding whitespace', () => {
    const list = [artifact({ id: 'x', reference: 'Repo://Docs/PRD/Spec.md' })]
    expect(artifactForReference(list, '  repo://docs/prd/spec.md ')?.id).toBe('x')
  })

  it('falls back to a title match when the reference does not match', () => {
    const list = [artifact({ id: 'y', reference: 'repo://other', title: 'My Title' })]
    expect(artifactForReference(list, 'my title')?.id).toBe('y')
  })

  it('returns undefined when nothing matches', () => {
    expect(artifactForReference([artifact()], 'nope://missing')).toBeUndefined()
  })
})

describe('artifactPositionLabel', () => {
  it('maps each known tag to its Chinese label', () => {
    expect(artifactPositionLabel('historical')).toBe('历史版本')
    expect(artifactPositionLabel('discarded')).toBe('已丢弃')
    expect(artifactPositionLabel('promoted')).toBe('已提升')
    expect(artifactPositionLabel('proposed')).toBe('提议中')
    expect(artifactPositionLabel('latest')).toBe('最新')
  })

  it('defaults to 最新 for undefined / unknown tags', () => {
    expect(artifactPositionLabel(undefined)).toBe('最新')
  })
})

describe('compactLabel', () => {
  it('returns the last path segment of a scheme reference', () => {
    expect(compactLabel('repo://docs/prd/spec.md')).toBe('spec.md')
  })

  it('strips a query string before splitting', () => {
    expect(compactLabel('https://x.com/path/page?foo=bar')).toBe('page')
  })

  it('falls back to the original value when there are no segments', () => {
    expect(compactLabel('plainlabel')).toBe('plainlabel')
  })
})

describe('dedupeStrings', () => {
  it('trims, drops empties/nullish, and removes duplicates preserving first order', () => {
    expect(dedupeStrings([' a ', 'a', null, undefined, '', '  ', 'b', 'a'])).toEqual(['a', 'b'])
  })

  it('returns an empty array when nothing survives', () => {
    expect(dedupeStrings([null, undefined, '   '])).toEqual([])
  })
})
