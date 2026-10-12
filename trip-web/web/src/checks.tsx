import { useCallback, useEffect, useState } from 'preact/hooks'
import { api } from './api'
import { dayLabel } from './format'
import { Icon } from './icons'
import type { CheckItem, CheckResult } from './types'
import { messageOf, useNotify } from './ui'

/** The smart checks for one trip. They are asked again whenever the trip changes (the revision), so they follow edits made on any screen. */
export function useChecks(tripId: string, revision: number) {
  const notify = useNotify()
  const [result, setResult] = useState<CheckResult | null>(null)
  const load = useCallback(async () => {
    try { setResult(await api.checks(tripId)) } catch (error) { notify(messageOf(error), true) }
  }, [tripId])
  useEffect(() => { void load() }, [load, revision])
  return { result, reload: load }
}

/** One warning with its icon: the icon and the word say how serious it is, not only the colour. */
function Line({ item, showDay }: { item: CheckItem; showDay?: boolean }) {
  return (
    <div class={`check-line ${item.severity}`}>
      <span class="check-icon"><Icon name={item.severity === 'warn' ? 'warn' : 'info'} size={18} /></span>
      <div>
        <div class="title">{item.title}</div>
        <div class="meta">{showDay && item.day ? `${dayLabel(item.day)} · ` : ''}{item.text}</div>
      </div>
    </div>
  )
}

/** Warnings that belong to one stop or one day, shown right where they apply. */
export function InlineChecks({ items }: { items: CheckItem[] }) {
  if (items.length === 0) return null
  return <div class="inline-checks">{items.map((item) => <div class={`inline-check ${item.severity}`} role="note"><Icon name={item.severity === 'warn' ? 'warn' : 'info'} size={16} /><span>{item.text}</span></div>)}</div>
}

/** The summary at the top of the plan: what to look at, with a jump to the place and a way to say "I know". */
export function CheckPanel(props: { tripId: string; result: CheckResult | null; canEdit: boolean; reload: () => Promise<void> }) {
  const notify = useNotify()
  const [all, setAll] = useState(false)
  const [showIgnored, setShowIgnored] = useState(false)
  const { result } = props
  if (!result) return null
  const { checks, ignored } = result
  const warnings = checks.filter((c) => c.severity === 'warn').length
  const shown = all ? checks : checks.slice(0, 4)

  const ignore = async (item: CheckItem, value: boolean) => {
    try { await api.ignoreCheck(props.tripId, item.key, value); await props.reload() } catch (error) { notify(messageOf(error), true) }
  }
  const jump = (item: CheckItem) => {
    if (item.leg_id) { location.hash = `#/trip/${encodeURIComponent(props.tripId)}/route`; return }
    const target = (item.stop_id ? document.querySelector(`[data-drag-item="${CSS.escape(item.stop_id)}"]`) : null) ?? (item.day ? document.querySelector(`[data-day="${item.day}"]`) : null)
    target?.scrollIntoView({ behavior: 'smooth', block: 'center' })
  }

  return (
    <section class="card check-panel" aria-labelledby="check-title">
      <div class="check-head">
        <h2 id="check-title">Prüfungen</h2>
        <span class={`badge ${warnings ? 'warn-badge' : ''}`}>{checks.length === 0 ? 'Alles in Ordnung' : `${warnings} Warnung${warnings === 1 ? '' : 'en'}${checks.length > warnings ? ` · ${checks.length - warnings} Hinweis${checks.length - warnings === 1 ? '' : 'e'}` : ''}`}</span>
      </div>
      {checks.length === 0 && <p class="note">Keine Auffälligkeiten bei Öffnungszeiten, Wegen, Anschlüssen und Tageslänge.{!result.holidays_checked && ' Für Feiertage fehlt das Land der Reise.'}</p>}
      {shown.map((item) => (
        <div class="row check-row">
          <Line item={item} showDay />
          <div class="check-actions">
            {(item.stop_id || item.day || item.leg_id) && <button type="button" class="btn quiet" onClick={() => jump(item)}>{item.leg_id ? 'Zur Route' : 'Anzeigen'}</button>}
            {props.canEdit && <button type="button" class="btn quiet" onClick={() => ignore(item, true)} title="Diese Warnung ausblenden">Ignorieren</button>}
          </div>
        </div>
      ))}
      {checks.length > 4 && <button type="button" class="link" onClick={() => setAll(!all)}>{all ? 'Weniger anzeigen' : `Alle ${checks.length} anzeigen`}</button>}
      {ignored.length > 0 && (
        <div class="check-ignored">
          <button type="button" class="link" aria-expanded={showIgnored} onClick={() => setShowIgnored(!showIgnored)}>Ausgeblendet ({ignored.length})</button>
          {showIgnored && ignored.map((item) => (
            <div class="row check-row dim"><Line item={item} showDay />{props.canEdit && <button type="button" class="btn quiet" onClick={() => ignore(item, false)}>Wieder zeigen</button>}</div>
          ))}
        </div>
      )}
      <p class="note">Wege sind Schätzungen. Öffnungszeiten prüft die Seite nur, wo sie eingetragen sind. Fahrpläne gibt es hier nicht.</p>
    </section>
  )
}
