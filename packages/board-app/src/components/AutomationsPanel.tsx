import { useEffect, useMemo, useState } from 'react'
import {
  createAutomation,
  deleteAutomation,
  fetchAutomations,
  runAutomation,
  type AutomationDefinition,
  type AutomationRun,
  type AutomationTemplate,
} from '../api'

interface Props {
  onClose: () => void
}

export function AutomationsPanel({ onClose }: Props) {
  const [templates, setTemplates] = useState<AutomationTemplate[]>([])
  const [automations, setAutomations] = useState<AutomationDefinition[]>([])
  const [selectedTemplateId, setSelectedTemplateId] = useState<string>('')
  const [draftTitle, setDraftTitle] = useState('')
  const [draftPrompt, setDraftPrompt] = useState('')
  const [draftCadence, setDraftCadence] = useState('Manual')
  const [busyId, setBusyId] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [latestRun, setLatestRun] = useState<AutomationRun | null>(null)

  useEffect(() => {
    let cancelled = false
    fetchAutomations()
      .then((data) => {
        if (cancelled) return
        setTemplates(data.templates)
        setAutomations(data.automations)
      })
      .catch((e) => {
        if (!cancelled) setError((e as Error).message)
      })
    return () => {
      cancelled = true
    }
  }, [])

  const groupedTemplates = useMemo(() => {
    const groups = new Map<string, AutomationTemplate[]>()
    for (const template of templates) {
      groups.set(template.category, [...(groups.get(template.category) ?? []), template])
    }
    return [...groups.entries()]
  }, [templates])

  const selectedTemplate = templates.find((template) => template.id === selectedTemplateId)

  const useTemplate = (template: AutomationTemplate) => {
    setSelectedTemplateId(template.id)
    setDraftTitle(template.title)
    setDraftPrompt(template.prompt)
    setDraftCadence(template.cadence)
  }

  const saveAutomation = async () => {
    setSaving(true)
    setError(null)
    try {
      const created = await createAutomation({
        title: draftTitle,
        prompt: draftPrompt,
        cadence: draftCadence,
        templateId: selectedTemplateId || undefined,
        description: selectedTemplate?.description,
      })
      setAutomations((prev) => [...prev, created])
      setDraftTitle('')
      setDraftPrompt('')
      setDraftCadence('Manual')
      setSelectedTemplateId('')
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setSaving(false)
    }
  }

  const executeAutomation = async (automation: AutomationDefinition) => {
    setBusyId(automation.id)
    setError(null)
    setLatestRun(null)
    try {
      const result = await runAutomation(automation.id)
      setAutomations((prev) => prev.map((item) => item.id === result.automation.id ? result.automation : item))
      setLatestRun(result.run)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusyId(null)
    }
  }

  const removeAutomation = async (id: string) => {
    setBusyId(id)
    setError(null)
    try {
      await deleteAutomation(id)
      setAutomations((prev) => prev.filter((item) => item.id !== id))
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusyId(null)
    }
  }

  return (
    <div className="automations-modal-backdrop" role="presentation" onMouseDown={onClose}>
      <section
        className="automations-modal"
        role="dialog"
        aria-modal="true"
        aria-label="Automations"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="automations-header">
          <div>
            <p className="automations-eyebrow">AI workflows</p>
            <h2>Automations</h2>
            <p>Create reusable local workflows and hand them to AI when you need a run.</p>
          </div>
          <button type="button" className="automations-close" onClick={onClose}>×</button>
        </header>

        {error && <div className="automations-error">{error}</div>}

        <div className="automations-grid">
          <div className="automations-column">
            <h3>Templates</h3>
            {groupedTemplates.map(([category, items]) => (
              <div className="automation-template-group" key={category}>
                <div className="automation-template-group__title">{category}</div>
                {items.map((template) => (
                  <button
                    type="button"
                    key={template.id}
                    className="automation-template-card"
                    onClick={() => useTemplate(template)}
                  >
                    <span className="automation-template-card__icon">{template.icon}</span>
                    <span>
                      <strong>{template.title}</strong>
                      <small>{template.description}</small>
                    </span>
                  </button>
                ))}
              </div>
            ))}
          </div>

          <div className="automations-column automations-column--editor">
            <h3>Create workflow</h3>
            <label>
              <span>Name</span>
              <input value={draftTitle} onChange={(event) => setDraftTitle(event.target.value)} placeholder="Weekly local status" />
            </label>
            <label>
              <span>Cadence note</span>
              <input value={draftCadence} onChange={(event) => setDraftCadence(event.target.value)} placeholder="Manual" />
            </label>
            <label>
              <span>AI instructions</span>
              <textarea value={draftPrompt} onChange={(event) => setDraftPrompt(event.target.value)} rows={9} />
            </label>
            <button
              type="button"
              className="automations-primary"
              disabled={saving || !draftPrompt.trim()}
              onClick={saveAutomation}
            >
              {saving ? 'Saving...' : 'Save automation'}
            </button>
          </div>

          <div className="automations-column">
            <h3>Your automations</h3>
            {automations.length === 0 && <p className="automations-muted">No saved automations yet.</p>}
            {automations.map((automation) => (
              <article className="automation-row" key={automation.id}>
                <div>
                  <strong>{automation.title}</strong>
                  <p>{automation.description || automation.prompt.slice(0, 140)}</p>
                  <small>{automation.cadence} · {automation.lastRunStatus ?? 'not run yet'}</small>
                </div>
                <div className="automation-row__actions">
                  <button type="button" disabled={busyId === automation.id} onClick={() => executeAutomation(automation)}>
                    {busyId === automation.id ? 'Running...' : 'Run'}
                  </button>
                  <button type="button" disabled={busyId === automation.id} onClick={() => removeAutomation(automation.id)}>
                    Delete
                  </button>
                </div>
              </article>
            ))}
          </div>
        </div>

        {latestRun && (
          <div className="automation-run-output">
            <div className="automation-run-output__title">Latest run · {latestRun.status}</div>
            <pre>{latestRun.error || latestRun.output || '(no output)'}</pre>
          </div>
        )}
      </section>
    </div>
  )
}
