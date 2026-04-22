// Tracks session IDs the user has explicitly removed from the canvas.
// When the last card for a sid is deleted, the sid enters this set so that
// the next WS tick's scene rebuild doesn't auto-re-add it. Adding back via
// sidebar's "Add to canvas" removes the sid from the set.

const STORAGE_KEY = 'meee2.board.dismissed.v1'

export type DismissedSet = Set<string>

export function loadDismissed(): DismissedSet {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return new Set()
    const parsed = JSON.parse(raw)
    if (Array.isArray(parsed)) return new Set(parsed.filter((x) => typeof x === 'string'))
  } catch {
    // ignore
  }
  return new Set()
}

export function saveDismissed(s: DismissedSet): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify([...s]))
  } catch {
    // ignore
  }
}
