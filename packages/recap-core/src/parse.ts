export interface ParsedAIRecap {
  headline: string
  summary: string
  details: string[]
}

export function parseAIRecap(raw: string): ParsedAIRecap {
  const text = raw.trim()
  const jsonText = text
    .replace(/^```(?:json)?/i, '')
    .replace(/```$/i, '')
    .trim()
  const objectMatch = jsonText.match(/\{[\s\S]*\}/)
  const candidate = objectMatch?.[0] ?? jsonText
  try {
    const parsed = JSON.parse(candidate) as { headline?: unknown; summary?: unknown; details?: unknown }
    const headline = typeof parsed.headline === 'string'
      ? trimToSentence(parsed.headline.trim(), 92)
      : trimToSentence(text, 92)
    const details = Array.isArray(parsed.details)
      ? parsed.details
        .filter((item): item is string => typeof item === 'string' && item.trim().length > 0)
        .slice(0, 6)
        .map((item) => trimToSentence(item.trim(), 180))
      : []
    const explicitSummary = typeof parsed.summary === 'string'
      ? trimToSentence(parsed.summary.trim(), 160)
      : ''
    const summary = explicitSummary || details[0] || ''
    return {
      headline: headline || 'AI recap generated.',
      summary,
      details: explicitSummary ? details : details.slice(1),
    }
  } catch {
    const lines = text.split('\n').map((line) => line.replace(/^[-*]\s*/, '').trim()).filter(Boolean)
    return {
      headline: trimToSentence(lines[0] ?? text, 92),
      summary: trimToSentence(lines[1] ?? '', 160),
      details: lines.slice(2, 8).map((line) => trimToSentence(line, 180)),
    }
  }
}

export function trimToSentence(value: string, maxLength: number): string {
  if (value.length <= maxLength) return value
  return `${value.slice(0, Math.max(0, maxLength - 3)).trimEnd()}...`
}
