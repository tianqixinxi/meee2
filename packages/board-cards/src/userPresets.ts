// 用户自定义 card preset 的 localStorage 存储。和 bundled TEMPLATE_PRESETS
// 并列显示在 gallery 里，选中时写到 session 的 card template。
//
// 数据仅在浏览器本地，不走后端（后端那层是 per-session template，语义不同：
//  - backend per-session template：把 X session 固定绑某段 TSX
//  - this user preset library：可复用的设计，像 built-in preset 一样可选
// 这两条最终都会把 source 写到 backend 的 card-templates/session-<sid>.tsx。

import type { TemplatePreset } from './templatePresets'

const STORAGE_KEY = 'meee2.user-presets.v1'

export function loadUserPresets(): TemplatePreset[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return []
    const arr = JSON.parse(raw)
    if (!Array.isArray(arr)) return []
    return arr.filter(isValidPreset)
  } catch { return [] }
}

export function saveUserPresets(list: TemplatePreset[]): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(list))
  } catch { /* quota */ }
}

export function addUserPreset(p: TemplatePreset): TemplatePreset[] {
  const list = loadUserPresets()
  // 同 id 覆盖（让 "重新保存同名" 行为一致）
  const existing = list.findIndex((x) => x.id === p.id)
  if (existing >= 0) list[existing] = p
  else list.push(p)
  saveUserPresets(list)
  return list
}

export function deleteUserPreset(id: string): TemplatePreset[] {
  const list = loadUserPresets().filter((p) => p.id !== id)
  saveUserPresets(list)
  return list
}

/** 从 label 推 id —— 小写 + 只留字母数字 + 前缀 `custom-`，确保不和 built-in 冲突 */
export function userPresetIdFromLabel(label: string): string {
  const slug = label.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
  return 'custom-' + (slug || Date.now().toString(36))
}

function isValidPreset(x: unknown): x is TemplatePreset {
  if (!x || typeof x !== 'object') return false
  const p = x as Record<string, unknown>
  return (
    typeof p.id === 'string' && !!p.id &&
    typeof p.label === 'string' && !!p.label &&
    typeof p.description === 'string' &&
    typeof p.source === 'string' && !!p.source
  )
}
