import { useEffect, useState } from 'preact/hooks'
import { api } from './api'
import { finalIndex, startDrag } from './dnd'
import { duration, modeColor } from './modes'
import { money, shortDate } from './format'
import { useOperation } from './plan'
import type { Timeline as TimelineData, TimelineStay } from './types'
import { Field, Skeleton, messageOf, useNotify } from './ui'

import type { ViewProps } from './views'

const GLYPH: Record<string, string> = { shinkansen: '🚄', train: '🚆', bus: '🚌', flight: '✈️', ferry: '⛴️', car: '🚗', taxi: '🚕', walk: '🚶', other: '•' }
const PALETTE = ['#0f7b6c', '#c62828', '#1e6fd0', '#e08a00', '#6a1b9a', '#00838f', '#6d4c41', '#ad1457', '#558b2f']
const colorOf = (index: number) => PALETTE[index % PALETTE.length]
const nightsLabel = (n: number) => `${n} ${n === 1 ? 'Nacht' : 'Nächte'}`

/** The trip as one bar: every stay as wide as its nights, with the way there marked between them. */
function Bar({ timeline }: { timeline: TimelineData }) {
  const { stays } = timeline
  const total = Math.max(timeline.available_nights, timeline.planned_nights, 1)
  return (
    <div class="tl-bar" role="img" aria-label={`Reise in ${stays.length} Aufenthalten, ${timeline.planned_nights} von ${timeline.available_nights} Nächten verplant`}>
      {stays.map((s, i) => (
        <div class="tl-seg" style={{ flexGrow: Math.max(s.nights, 0.25), flexBasis: 0, background: colorOf(i) }} title={`${s.name}: ${nightsLabel(s.nights)} (${shortDate(s.arrive)} bis ${shortDate(s.leave)})`}>
          {i > 0 && s.arrival && <span class="tl-travel" style={{ color: modeColor(s.arrival.mode) }} aria-hidden="true">{GLYPH[s.arrival.mode] ?? '•'}</span>}
          <span class="tl-name">{s.name}</span>
          <span class="tl-nights">{s.nights}</span>
        </div>
      ))}
      {timeline.planned_nights < timeline.available_nights && (
        <div class="tl-seg tl-free" style={{ flexGrow: timeline.available_nights - timeline.planned_nights, flexBasis: 0 }} title="Noch nicht verplant">
          <span class="tl-name">frei</span><span class="tl-nights">{timeline.available_nights - timeline.planned_nights}</span>
        </div>
      )}
      <span class="sr-only">{total} Nächte insgesamt</span>
    </div>
  )
}

function StayCard(props: { stay: TimelineStay; index: number; count: number; canEdit: boolean; currency: string; travelers: number; onNights: (n: number) => void;
  onMove: (delta: -1 | 1) => void; onDragTo: (index: number) => void; onRemove: () => void; onNotes: (text: string) => Promise<void> }) {
  const { stay: s } = props
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(s.notes)
  const [saving, setSaving] = useState(false)
  const a = s.arrival
  return (
    <section class="card stay" aria-label={s.name} data-drag-item={s.id} data-drag-group="stays" data-drag-index={props.index}>
      <div class="stay-head">
        {props.canEdit && (
          <button type="button" class="grip" aria-label={`${s.name} ziehen`} title="Ziehen zum Umordnen"
            onPointerDown={(e) => startDrag(e as unknown as PointerEvent, (d) => props.onDragTo(finalIndex(d.fromGroup, d.fromIndex, d.group, d.before)))}>⠿</button>
        )}
        <span class="stay-dot" style={{ background: colorOf(props.index) }} />
        <h3>{s.name}</h3>
        {props.canEdit && (
          <div class="hop-move">
            <button type="button" class="btn quiet" aria-label={`${s.name} nach oben`} disabled={props.index === 0} onClick={() => props.onMove(-1)}>↑</button>
            <button type="button" class="btn quiet" aria-label={`${s.name} nach unten`} disabled={props.index === props.count - 1} onClick={() => props.onMove(1)}>↓</button>
          </div>
        )}
      </div>
      <div class="meta">{shortDate(s.arrive)} bis {shortDate(s.leave)}</div>
      {editing ? (
        <form class="stay-notes-form" onSubmit={async (e) => { e.preventDefault(); setSaving(true); await props.onNotes(draft.trim()); setSaving(false); setEditing(false) }}>
          <Field label="Was machen wir hier?" hint="Zum Beispiel: Tagesausflug nach Nikko, Asakusa, teamLab, abends Shibuya.">
            <textarea rows={4} value={draft} maxLength={4000} onInput={(e) => setDraft((e.target as HTMLTextAreaElement).value)} />
          </Field>
          <div class="actions">
            <button class="btn" type="submit" disabled={saving}>Speichern</button>
            <button class="btn quiet" type="button" onClick={() => { setDraft(s.notes); setEditing(false) }}>Abbrechen</button>
          </div>
        </form>
      ) : (
        <>
          {s.notes ? <p class="stay-notes">{s.notes}</p> : props.canEdit ? <p class="note">Noch keine Beschreibung.</p> : null}
          {props.canEdit && <button type="button" class="link" onClick={() => { setDraft(s.notes); setEditing(true) }}>{s.notes ? 'Beschreibung ändern' : 'Beschreibung hinzufügen'}</button>}
        </>
      )}
      <div class="stay-nights">
        {props.canEdit && <button type="button" class="btn secondary stepper" aria-label={`Eine Nacht weniger in ${s.name}`} disabled={s.nights <= 0} onClick={() => props.onNights(s.nights - 1)}>−</button>}
        <b>{nightsLabel(s.nights)}</b>
        {props.canEdit && <button type="button" class="btn secondary stepper" aria-label={`Eine Nacht mehr in ${s.name}`} disabled={s.nights >= 60} onClick={() => props.onNights(s.nights + 1)}>+</button>}
      </div>
      {a && (
        <div class="meta">
          Anreise: <span class="mode" style={{ background: modeColor(a.mode), color: '#fff', padding: '1px 8px', borderRadius: 999 }}>{a.mode_label}</span> {a.line}
          {[duration(a.duration_minutes), a.price_in_trip_currency ? `${money(a.price_in_trip_currency, props.currency)} p. P.` : ''].filter(Boolean).map((x) => ` · ${x}`)}
          {!a.chosen && ' (noch nicht gewählt)'}
        </div>
      )}
      <div class="meta">{s.ideas === 0 ? 'Noch keine Ideen für diesen Ort.' : `${s.ideas} ${s.ideas === 1 ? 'Idee' : 'Ideen'}${s.must ? `, davon ${s.must} Muss` : ''}${s.likes ? `, ${s.likes} 👍` : ''}`}</div>
      {props.canEdit && <div class="actions"><button type="button" class="btn quiet" onClick={props.onRemove}>Entfernen</button></div>}
    </section>
  )
}

export function Timeline({ data, canEdit, reload }: ViewProps) {
  const { trip } = data
  const notify = useNotify()
  const run = useOperation(reload)
  const [timeline, setTimeline] = useState<TimelineData | null>(null)
  const [name, setName] = useState('')
  const [nights, setNights] = useState('2')

  useEffect(() => { api.timeline(trip.id).then(setTimeline).catch((e) => notify(messageOf(e), true)) }, [trip.id, data.revision])

  if (!timeline) return <Skeleton lines={4} />
  const stays = timeline.stays
  const order = [...data.stays].sort((a, b) => a.sort_order - b.sort_order)

  const setStayNights = (id: string, value: number) => run('Nächte geändert', () => api.patch('stay', id, { nights: value }) as never)
  const move = (index: number, delta: -1 | 1) => moveTo(index, index + delta)
  const moveTo = async (index: number, target: number) => {
    if (!order[index] || target < 0 || target >= order.length || target === index) return
    try {
      // Renumber the whole list: two equal sort values could not be swapped.
      const next = [...order]; const [taken] = next.splice(index, 1); next.splice(target, 0, taken)
      await Promise.all(next.map((s, i) => (s.sort_order !== i ? api.patch('stay', s.id, { sort_order: i }) : null)))
      await reload()
    } catch (error) { notify(messageOf(error), true) }
  }
  const remove = (id: string, label: string) => run(`${label} entfernt`, () => api.deleteItem('stay', id))
  const add = async (event: Event) => {
    event.preventDefault()
    try {
      await api.createItem(trip.id, 'stay', { name: name.trim(), nights: Math.max(0, Math.min(60, Number(nights) || 0)) })
      setName(''); await reload()
    } catch (error) { notify(messageOf(error), true) }
  }
  const fromRoute = async () => {
    try {
      const route = await api.route(trip.id)
      const have = new Set(order.map((s) => s.name.trim().toLowerCase()))
      const missing = route.places.filter((p) => !have.has(p.name.trim().toLowerCase()))
      if (missing.length === 0) { notify('Alle Orte der Route sind schon im Zeitplan.'); return }
      for (const p of missing) await api.createItem(trip.id, 'stay', { name: p.name, nights: 2, ...(p.has_position ? { latitude: p.latitude, longitude: p.longitude } : {}) })
      await reload(); notify(`${missing.length} ${missing.length === 1 ? 'Ort' : 'Orte'} aus der Route übernommen (je 2 Nächte).`)
    } catch (error) { notify(messageOf(error), true) }
  }

  const left = timeline.available_nights - timeline.planned_nights
  return (
    <>
      <div class="card">
        <div class="row"><div class="body">
          <div class="title">{timeline.planned_nights} von {timeline.available_nights} Nächten verplant</div>
          <div class={`meter${left < 0 ? ' over' : ''}`}><span style={{ width: `${Math.min(100, (timeline.planned_nights / Math.max(timeline.available_nights, 1)) * 100)}%` }} /></div>
          <div class="meta">{shortDate(timeline.start)} bis {shortDate(timeline.end)}{left > 0 ? ` · noch ${nightsLabel(left)} frei` : left < 0 ? ` · ${nightsLabel(-left)} zu viel` : ' · passt genau'}</div>
        </div></div>
      </div>
      {stays.length > 0 && <Bar timeline={timeline} />}
      {timeline.warnings.map((w) => <p class="meta warn" role="status">{w}</p>)}
      {stays.length === 0 && <p class="empty">Noch kein Zeitplan. Lege fest, wie viele Nächte ihr wo bleibt, oder übernimm die Orte aus der Route.</p>}
      {stays.map((s, i) => (
        <StayCard stay={s} index={i} count={stays.length} canEdit={canEdit} currency={trip.currency_code} travelers={trip.travelers} onNights={(n) => setStayNights(s.id, n)}
          onMove={(d) => move(i, d)} onDragTo={(to) => moveTo(i, to)} onRemove={() => remove(s.id, s.name)}
          onNotes={async (text) => { try { await api.patch('stay', s.id, { notes: text }); await reload() } catch (error) { notify(messageOf(error), true) } }} />
      ))}
      {canEdit && (
        <>
          <form class="add-item" onSubmit={add}>
            <Field label="Ort"><input value={name} required maxLength={200} placeholder="z. B. Kyoto" onInput={(e) => setName((e.target as HTMLInputElement).value)} /></Field>
            <Field label="Nächte"><input inputMode="numeric" value={nights} onInput={(e) => setNights((e.target as HTMLInputElement).value)} /></Field>
            <button class="btn" type="submit">Aufenthalt hinzufügen</button>
          </form>
          <div class="actions"><button type="button" class="btn secondary" onClick={fromRoute}>Orte aus der Route übernehmen</button></div>
        </>
      )}
    </>
  )
}
