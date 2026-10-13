import { useState } from 'preact/hooks'
import { api, type Done } from './api'
import { finalIndex, startDrag } from './dnd'
import { biasOf, PlaceSearch } from './edit'
import { dayLabel, mapsUrl, money, safeUrl, timeLabel } from './format'
import type { Day, FoundPlace, Place, Stop, TripData } from './types'
import { Field, Menu, Modal, messageOf, useNotify } from './ui'
import type { ViewProps } from './views'
import { CheckPanel, InlineChecks, useChecks } from './checks'
import type { CheckItem } from './types'

export const CATEGORY_LABEL: Record<string, string> = {
  sight: 'Sehenswürdigkeit', food: 'Essen', cafe: 'Café', hotel: 'Hotel', transport: 'Transport', nightlife: 'Nachtleben', other: 'Sonstiges',
}

/** Runs one plan operation, reloads, and offers to undo it (every operation is a single entry in the history). */
export function useOperation(reload: () => Promise<void>) {
  const notify = useNotify()
  const run = async (label: string, call: () => Promise<Done>) => {
    try {
      const done = await call()
      await reload()
      if (!done.change_id) { notify('Es musste nichts geändert werden.'); return done }
      notify(label, false, { label: 'Rückgängig', run: () => { api.undo(done.change_id!).then(reload).catch((e) => notify(messageOf(e), true)) } })
      return done
    } catch (error) {
      notify(messageOf(error), true)
      return null
    }
  }
  return Object.assign(run, { reload })
}

const metres = (a: { latitude: number; longitude: number }, b: { latitude: number; longitude: number }) => {
  const rad = Math.PI / 180
  const h = Math.sin(((b.latitude - a.latitude) * rad) / 2) ** 2 + Math.cos(a.latitude * rad) * Math.cos(b.latitude * rad) * Math.sin(((b.longitude - a.longitude) * rad) / 2) ** 2
  return 2 * 6371008.8 * Math.asin(Math.sqrt(h))
}

/** The app's rule against adding the same place twice on a day: same name, and within 100 m (or no position to compare). */
const alreadyThere = (stops: Stop[], name: string, latitude?: number, longitude?: number) =>
  stops.some((s) => s.name.trim().toLowerCase() === name.trim().toLowerCase()
    && (!(s.latitude || s.longitude) || latitude === undefined || longitude === undefined || metres(s, { latitude, longitude }) < 100))

export function Plan(props: ViewProps) {
  const { data, canEdit, reload } = props
  const run = useOperation(reload)
  const [dialog, setDialog] = useState<
    { kind: 'add'; day: Day } | { kind: 'edit'; stop: Stop } | { kind: 'move'; stop: Stop } | { kind: 'copy'; day: Day } | { kind: 'retime'; day: Day } | null
  >(null)
  const { trip, days, bookings } = data
  const { result: checks, reload: reloadChecks } = useChecks(trip.id, data.revision)

  if (days.length === 0) return <p class="empty">Keine Tage. Ändere die Reisedaten, damit Tage entstehen.</p>

  return (
    <>
      {canEdit && bookings.length > 0 && (
        <div class="actions">
          <button class="btn secondary" onClick={() => run('Flüge und Hotels in den Plan gelegt', () => api.bookingStops(trip.id))}>Flüge und Hotels in den Plan legen</button>
        </div>
      )}
      <CheckPanel tripId={trip.id} result={checks} canEdit={canEdit} reload={reloadChecks} />
      {days.map((day, index) => (
        <DayCard key={day.id} checks={checks?.checks ?? []} data={data} day={day} number={index + 1} canEdit={canEdit} run={run} mutate={props.mutate} setDialog={setDialog} />
      ))}
      {dialog?.kind === 'add' && <AddStopDialog data={data} day={dialog.day} run={run} onClose={() => setDialog(null)} />}
      {dialog?.kind === 'edit' && <StopDialog data={data} stop={dialog.stop} reload={reload} onClose={() => setDialog(null)} />}
      {dialog?.kind === 'move' && <MoveDialog data={data} stop={dialog.stop} run={run} onClose={() => setDialog(null)} />}
      {dialog?.kind === 'copy' && <CopyDialog data={data} day={dialog.day} run={run} onClose={() => setDialog(null)} />}
      {dialog?.kind === 'retime' && <RetimeDialog day={dialog.day} run={run} onClose={() => setDialog(null)} />}
    </>
  )
}

type Operation = ReturnType<typeof useOperation>

function DayCard(props: { checks: CheckItem[]; data: TripData; day: Day; number: number; canEdit: boolean; run: Operation; mutate: ViewProps['mutate']; setDialog: (d: never) => void }) {
  const { data, day, run, canEdit } = props
  const { trip } = data
  const list = data.stops.filter((s) => s.day_id === day.id).sort((a, b) => a.sort_order - b.sort_order)
  const window = data.windows?.[day.date]
  const cost = list.reduce((sum, s) => sum + (s.estimated_cost || 0), 0)
  const open = (dialog: object) => props.setDialog(dialog as never)

  const dayMenu = [
    { label: 'Zeiten anpassen …', onSelect: () => open({ kind: 'retime', day }) },
    { label: 'Nach Zeit sortieren', onSelect: () => run('Nach Zeit sortiert', () => api.sortDay(day.id)) },
    { label: 'Route optimieren', onSelect: () => run('Route optimiert', () => api.optimizeDay(day.id)) },
    { label: 'Tag kopieren nach …', onSelect: () => open({ kind: 'copy', day }) },
  ]

  return (
    <section aria-label={`Tag ${props.number}`} data-day={day.date}>
      <div class="day-head">
        <h2>Tag {props.number} · {dayLabel(day.date)}</h2>
        {canEdit && list.length > 0 && <Menu label="Tag" items={dayMenu} />}
      </div>
      <div class="card" data-drag-container={day.id}>
        {window && (window.start || window.end || window.hotel || window.items.length > 0) && (
          <div class="window note">
            {window.start && <div>Frühester Start: {window.start} (nach der Landung)</div>}
            {window.end && <div>Spätestens fertig: {window.end} (Weg zum Flughafen)</div>}
            {window.hotel && <div>Start im Hotel: {window.hotel}</div>}
            {window.items.map((i) => <div>{i.time} · {i.text}</div>)}
          </div>
        )}
        <InlineChecks items={props.checks.filter((c) => c.day === day.date && !c.stop_id && !c.leg_id)} />
        {day.notes && <p class="note">{day.notes}</p>}
        {list.length === 0 && <p class="empty">Noch keine Stopps.</p>}
        {list.map((stop, i) => (
          <StopRow key={stop.id} stop={stop} dayId={day.id} position={i} first={i === 0} last={i === list.length - 1} currency={trip.currency_code} canEdit={canEdit} run={run} mutate={props.mutate} open={open} checks={props.checks.filter((c) => c.stop_id === stop.id)} />
        ))}
        {cost > 0 && <div class="row total"><div class="body meta">Geplant an diesem Tag</div><div class="end">{money(cost, trip.currency_code)}</div></div>}
        {canEdit && <div class="actions"><button class="btn secondary" onClick={() => open({ kind: 'add', day })}>Stopp hinzufügen</button></div>}
      </div>
    </section>
  )
}

function StopRow(props: { checks: CheckItem[]; stop: Stop; dayId: string; position: number; first: boolean; last: boolean; currency: string; canEdit: boolean; run: Operation; mutate: ViewProps['mutate']; open: (d: object) => void }) {
  const { stop: s, run, canEdit } = props
  const notify = useNotify()
  const link = safeUrl(s.website)
  const index = (delta: number) => run('Stopp verschoben', () => api.moveStop(s.id, { index: Math.max(0, s.sort_order + delta) }))
  const toggle = async (done: boolean) => {
    props.mutate((d) => ({ ...d, stops: d.stops.map((x) => (x.id === s.id ? { ...x, is_done: done } : x)) }))
    try { await api.patch('stop', s.id, { is_done: done }); await run.reload() } catch (error) { notify(messageOf(error), true); await run.reload() }
  }
  return (
    <div class={`row${s.is_done ? ' done' : ''}`} data-drag-item={s.id} data-drag-group={props.dayId} data-drag-index={props.position}>
      {canEdit && (
        <button type="button" class="grip" aria-label={`${s.name} ziehen`} title="Ziehen zum Verschieben"
          onPointerDown={(e) => startDrag(e as unknown as PointerEvent, (d) => {
            const to = finalIndex(d.fromGroup, d.fromIndex, d.group, d.before)
            if (d.group === d.fromGroup && to === d.fromIndex) return
            void run('Stopp verschoben', () => api.moveStop(s.id, d.group === d.fromGroup ? { index: to } : { day_id: d.group, index: to }))
          })}>⠿</button>
      )}
      {canEdit && <input type="checkbox" class="tick" aria-label={`${s.name} erledigt`} checked={s.is_done} onChange={(e) => toggle((e.target as HTMLInputElement).checked)} />}
      <div class="time">{s.planned_time ? timeLabel(s.planned_time) : ''}</div>
      <div class="body">
        <div class="title">{s.name}</div>
        <div class="meta">{[CATEGORY_LABEL[s.category_raw], s.address, s.duration_minutes ? `${s.duration_minutes} Min.` : '', s.opening_hours].filter(Boolean).join(' · ')}</div>
        {s.notes && <div class="meta">{s.notes}</div>}
        <InlineChecks items={props.checks} />
        <div class="meta links">
          <a href={mapsUrl(s)} target="_blank" rel="noopener noreferrer">Google Maps</a>
          {link && <a href={link} target="_blank" rel="noopener noreferrer">Webseite</a>}
        </div>
      </div>
      {s.estimated_cost > 0 && <div class="end meta">{money(s.estimated_cost, props.currency)}</div>}
      {canEdit && (
        <Menu label="…" ariaLabel="Weitere Aktionen für diesen Stopp" items={[
          { label: 'Bearbeiten', onSelect: () => props.open({ kind: 'edit', stop: s }) },
          ...(props.first ? [] : [{ label: 'Nach oben', onSelect: () => index(-1) }]),
          ...(props.last ? [] : [{ label: 'Nach unten', onSelect: () => index(1) }]),
          { label: 'Auf anderen Tag …', onSelect: () => props.open({ kind: 'move', stop: s }) },
          { label: 'Duplizieren', onSelect: () => run('Stopp kopiert', () => api.duplicateStop(s.id)) },
          { label: 'Löschen', danger: true, onSelect: () => run('Stopp gelöscht', () => api.deleteItem('stop', s.id)) },
        ]} />
      )}
    </div>
  )
}

// MARK: Dialogs

function AddStopDialog(props: { data: TripData; day: Day; run: Operation; onClose: () => void }) {
  const notify = useNotify()
  const { data, day } = props
  const existing = data.stops.filter((s) => s.day_id === day.id)
  const [name, setName] = useState('')
  const [filter, setFilter] = useState('')
  const ideas = data.places
    .filter((p) => p.decision !== 'Nein' && p.prio !== 'Flughafen' && !existing.some((s) => s.place_id === p.id) && p.name.toLowerCase().includes(filter.toLowerCase()))
    .sort((a, b) => ['Muss', 'Gerne', 'Falls Zeit'].indexOf(a.prio) - ['Muss', 'Gerne', 'Falls Zeit'].indexOf(b.prio))

  const add = async (stop: Record<string, unknown>, label: string) => {
    if (await props.run(label, () => api.createItem(data.trip.id, 'stop', { day_id: day.id, ...stop }))) props.onClose()
  }
  const addFound = (found: FoundPlace) => {
    if (alreadyThere(existing, found.name, found.latitude, found.longitude)) { notify(`„${found.name}“ steht an diesem Tag schon im Plan.`, true); return }
    void add({ name: found.name, address: found.address, category_raw: found.category_raw, latitude: found.latitude, longitude: found.longitude }, `Hinzugefügt: ${found.name}`)
  }
  const addIdea = async (place: Place) => {
    const done = await props.run(`Auf den Tag gelegt: ${place.name}`, () => api.placeToDay(place.id, day.id))
    if (done) props.onClose()
  }
  const addByName = (event: Event) => {
    event.preventDefault()
    if (alreadyThere(existing, name)) { notify(`„${name}“ steht an diesem Tag schon im Plan.`, true); return }
    void add({ name }, `Hinzugefügt: ${name}`)
  }

  return (
    <Modal title={`Stopp hinzufügen · ${dayLabel(day.date)}`} onClose={props.onClose}>
      <PlaceSearch near={biasOf(data)} label="Ort suchen" onPick={addFound} />
      <h3>Aus den Ideen</h3>
      <input type="search" placeholder="Ideen filtern" aria-label="Ideen filtern" value={filter} onInput={(e) => setFilter((e.target as HTMLInputElement).value)} />
      <div class="card results">
        {ideas.length === 0 && <p class="empty">Keine passende Idee.</p>}
        {ideas.slice(0, 40).map((p) => (
          <button type="button" class="row trip-row" onClick={() => addIdea(p)}>
            <div class="body"><div class="title">{p.name}</div><div class="meta">{[p.prio, p.region, p.duration].filter(Boolean).join(' · ')}</div></div>
          </button>
        ))}
      </div>
      <h3>Von Hand</h3>
      <form class="two" onSubmit={addByName}>
        <input value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} placeholder="Name, ohne Position" aria-label="Name" required maxLength={200} />
        <button class="btn" type="submit">Hinzufügen</button>
      </form>
      <div class="actions"><button class="btn quiet" onClick={props.onClose}>Schliessen</button></div>
    </Modal>
  )
}

function StopDialog(props: { data: TripData; stop: Stop; reload: () => Promise<void>; onClose: () => void }) {
  const notify = useNotify()
  const s = props.stop
  const day = props.data.days.find((d) => d.id === s.day_id)!
  const [name, setName] = useState(s.name)
  const [category, setCategory] = useState(s.category_raw)
  const [timed, setTimed] = useState(Boolean(s.planned_time))
  const [time, setTime] = useState(s.planned_time ? timeLabel(s.planned_time) : '09:00')
  const [minutes, setMinutes] = useState(String(s.duration_minutes || 60))
  const [cost, setCost] = useState(String(s.estimated_cost || 0))
  const [address, setAddress] = useState(s.address)
  const [phone, setPhone] = useState(s.phone)
  const [website, setWebsite] = useState(s.website)
  const [hours, setHours] = useState(s.opening_hours)
  const [notes, setNotes] = useState(s.notes)
  const [position, setPosition] = useState<{ latitude: number; longitude: number } | null>(s.latitude || s.longitude ? { latitude: s.latitude, longitude: s.longitude } : null)
  const [busy, setBusy] = useState(false)
  const text = (set: (v: string) => void) => (e: Event) => set((e.target as HTMLInputElement | HTMLTextAreaElement).value)

  const submit = async (event: Event) => {
    event.preventDefault()
    setBusy(true)
    try {
      await api.patch('stop', s.id, {
        name, category_raw: category, planned_time: timed ? `${day.date}T${time}` : null,
        duration_minutes: Math.max(0, Math.min(1440, Math.round(Number(minutes) || 60))), estimated_cost: Math.max(0, Number(cost.replace(',', '.')) || 0),
        address, phone, website, opening_hours: hours, notes, ...(position ?? {}),
      })
      await props.reload()
      props.onClose()
    } catch (error) { notify(messageOf(error), true); setBusy(false) }
  }
  const found = (f: FoundPlace) => {
    setPosition({ latitude: f.latitude, longitude: f.longitude })
    if (!address.trim()) setAddress(f.address)
  }

  return (
    <Modal title="Stopp bearbeiten" onClose={props.onClose}>
      <form onSubmit={submit}>
        <PlaceSearch near={biasOf(props.data)} label="Position neu suchen" onPick={found} />
        <Field label="Name"><input value={name} onInput={text(setName)} required maxLength={200} /></Field>
        <Field label="Art">
          <select value={category} onChange={(e) => setCategory((e.target as HTMLSelectElement).value)}>
            {Object.entries(CATEGORY_LABEL).map(([id, label]) => <option value={id}>{label}</option>)}
          </select>
        </Field>
        <label class="check"><input type="checkbox" checked={timed} onChange={(e) => setTimed((e.target as HTMLInputElement).checked)} /> Mit Uhrzeit</label>
        <div class="two">
          <Field label="Uhrzeit"><input type="time" value={time} disabled={!timed} onInput={text(setTime)} /></Field>
          <Field label="Dauer (Minuten)"><input inputMode="numeric" value={minutes} onInput={text(setMinutes)} /></Field>
        </div>
        <Field label={`Geschätzte Kosten (${props.data.trip.currency_code})`}><input inputMode="decimal" value={cost} onInput={text(setCost)} /></Field>
        <Field label="Adresse"><input value={address} onInput={text(setAddress)} maxLength={300} /></Field>
        <div class="two">
          <Field label="Telefon"><input value={phone} onInput={text(setPhone)} maxLength={60} /></Field>
          <Field label="Webseite"><input type="url" value={website} onInput={text(setWebsite)} placeholder="https://…" /></Field>
        </div>
        <Field label="Öffnungszeiten"><input value={hours} onInput={text(setHours)} maxLength={500} /></Field>
        <Field label="Notizen"><textarea rows={3} value={notes} onInput={text(setNotes)} /></Field>
        <p class="note">{position ? `Position gesetzt (${position.latitude.toFixed(4)}, ${position.longitude.toFixed(4)}).` : 'Keine Position: Routen und Zeiten können diesen Stopp nicht berücksichtigen.'}</p>
        <div class="actions">
          <button class="btn" type="submit" disabled={busy}>Speichern</button>
          <button class="btn quiet" type="button" onClick={props.onClose}>Abbrechen</button>
        </div>
      </form>
    </Modal>
  )
}

function DayPicker(props: { data: TripData; except: string; value: string; onChange: (id: string) => void }) {
  return (
    <select value={props.value} onChange={(e) => props.onChange((e.target as HTMLSelectElement).value)} aria-label="Tag">
      {props.data.days.filter((d) => d.id !== props.except).map((d) => <option value={d.id}>{dayLabel(d.date)}</option>)}
    </select>
  )
}

function MoveDialog(props: { data: TripData; stop: Stop; run: Operation; onClose: () => void }) {
  const other = props.data.days.find((d) => d.id !== props.stop.day_id)
  const [target, setTarget] = useState(other?.id ?? '')
  const go = async (event: Event) => {
    event.preventDefault()
    if (await props.run(`„${props.stop.name}“ verschoben`, () => api.moveStop(props.stop.id, { day_id: target }))) props.onClose()
  }
  return (
    <Modal title={`„${props.stop.name}“ verschieben`} onClose={props.onClose}>
      <form onSubmit={go}>
        <p class="note">Die Uhrzeit bleibt, der Stopp kommt ans Ende des gewählten Tages.</p>
        <Field label="Auf den Tag"><DayPicker data={props.data} except={props.stop.day_id} value={target} onChange={setTarget} /></Field>
        <div class="actions"><button class="btn" type="submit" disabled={!target}>Verschieben</button><button class="btn quiet" type="button" onClick={props.onClose}>Abbrechen</button></div>
      </form>
    </Modal>
  )
}

function CopyDialog(props: { data: TripData; day: Day; run: Operation; onClose: () => void }) {
  const other = props.data.days.find((d) => d.id !== props.day.id)
  const [target, setTarget] = useState(other?.id ?? '')
  const go = async (event: Event) => {
    event.preventDefault()
    if (await props.run('Tag kopiert', () => api.copyDay(props.day.id, target))) props.onClose()
  }
  return (
    <Modal title={`${dayLabel(props.day.date)} kopieren`} onClose={props.onClose}>
      <form onSubmit={go}>
        <p class="note">Kopien aller Stopps kommen ans Ende des gewählten Tages, mit angepasstem Datum und nicht als erledigt markiert.</p>
        <Field label="Nach"><DayPicker data={props.data} except={props.day.id} value={target} onChange={setTarget} /></Field>
        <div class="actions"><button class="btn" type="submit" disabled={!target}>Kopieren</button><button class="btn quiet" type="button" onClick={props.onClose}>Abbrechen</button></div>
      </form>
    </Modal>
  )
}

function RetimeDialog(props: { day: Day; run: Operation; onClose: () => void }) {
  const [start, setStart] = useState('')
  const go = async (event: Event) => {
    event.preventDefault()
    if (await props.run('Zeiten angepasst', () => api.retimeDay(props.day.id, start || undefined))) props.onClose()
  }
  return (
    <Modal title="Zeiten anpassen" onClose={props.onClose}>
      <form onSubmit={go}>
        <p class="note">Die Stopps werden in der jetzigen Reihenfolge hintereinander gelegt, mit dem Weg dazwischen (Luftlinie plus Umweg) und 5 Minuten Puffer. Ohne Startzeit beginnt der Tag bei der frühesten vorhandenen Uhrzeit, sonst um 9:00, und nicht vor der Landung.</p>
        <Field label="Startzeit (leer lassen für automatisch)"><input type="time" value={start} onInput={(e) => setStart((e.target as HTMLInputElement).value)} /></Field>
        <div class="actions"><button class="btn" type="submit">Anpassen</button><button class="btn quiet" type="button" onClick={props.onClose}>Abbrechen</button></div>
      </form>
    </Modal>
  )
}
