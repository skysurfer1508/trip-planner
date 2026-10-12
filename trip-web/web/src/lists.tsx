import { useEffect, useState } from 'preact/hooks'
import { api } from './api'
import { biasOf, PlaceSearch } from './edit'
import { dateTimeLabel, dayLabel, money } from './format'
import { useOperation } from './plan'
import type { Booking, BudgetSummary, ChecklistItem, Expense, FoundPlace, TripData } from './types'
import { Field, Modal, Skeleton, messageOf, useNotify, ConfirmButton } from './ui'
import type { ViewProps } from './views'

const text = (set: (v: string) => void) => (e: Event) => set((e.target as HTMLInputElement | HTMLTextAreaElement).value)
const CURRENCIES = ['CHF', 'EUR', 'USD', 'GBP', 'PLN', 'JPY', 'CZK', 'HUF', 'SEK', 'NOK', 'DKK']

// MARK: Budget

export const EXPENSE_LABEL: Record<string, string> = {
  food: 'Essen', transport: 'Transport', lodging: 'Unterkunft', activities: 'Aktivitäten', shopping: 'Einkaufen', other: 'Sonstiges',
}

export function Budget({ data, canEdit, reload }: ViewProps) {
  const { trip, expenses } = data
  const [summary, setSummary] = useState<BudgetSummary | null>(null)
  const [editing, setEditing] = useState<Expense | 'new' | null>(null)
  const notify = useNotify()

  useEffect(() => {
    api.budget(trip.id).then(setSummary).catch((e) => notify(messageOf(e), true))
  }, [trip.id, data.revision])

  const byDay = new Map<string, Expense[]>()
  for (const e of [...expenses].sort((a, b) => b.date.localeCompare(a.date))) byDay.set(e.date, [...(byDay.get(e.date) ?? []), e])

  return (
    <>
      {canEdit && <div class="actions"><button class="btn" onClick={() => setEditing('new')}>Ausgabe hinzufügen</button></div>}
      {!summary && <Skeleton lines={3} />}
      {summary && (
        <div class="card">
          <div class="row"><div class="body">
            <div class="title">{money(summary.spent, summary.currency)}{summary.budget > 0 ? ` von ${money(summary.budget, summary.currency)}` : ''}</div>
            <div class={`meter${summary.over ? ' over' : ''}`}><span style={{ width: `${Math.min(100, summary.percent ?? 0)}%` }} /></div>
            {summary.budget > 0
              ? <div class="meta">{summary.over ? `${money(-summary.left, summary.currency)} über dem Budget` : `${money(summary.left, summary.currency)} übrig`}{summary.percent !== null ? ` · ${Math.round(summary.percent)} %` : ''}</div>
              : <div class="meta">Noch kein Budget festgelegt (Reise bearbeiten).</div>}
            {summary.planned > 0 && <div class="meta">In Stopps geplant: {money(summary.planned, summary.currency)}</div>}
            {(summary.planned_travel ?? 0) > 0 && <div class="meta">Fahrten der Route geplant: {money(summary.planned_travel!, summary.currency)}</div>}
            {summary.unconverted.length > 0 && (
              <div class="meta warn">{summary.rates_known ? 'Diese Währungen kenne ich nicht' : 'Die Wechselkurse sind gerade nicht erreichbar'}, darum zählen {summary.unconverted.length} Ausgabe(n) nicht mit: {summary.unconverted.map((u) => u.title).join(', ')}</div>
            )}
          </div></div>
        </div>
      )}
      {summary && summary.by_category.length > 0 && (
        <>
          <h2>Nach Art</h2>
          <div class="card">
            {summary.by_category.map((c) => <div class="row"><div class="body title">{EXPENSE_LABEL[c.category] ?? c.category}</div><div class="end">{money(c.total, summary.currency)}</div></div>)}
          </div>
        </>
      )}
      {expenses.length === 0 && <p class="empty">Noch keine Ausgaben.</p>}
      {[...byDay.entries()].map(([date, list]) => (
        <>
          <h2>{dayLabel(date)}{summary?.by_day.find((d) => d.date === date) ? ` · ${money(summary.by_day.find((d) => d.date === date)!.total, summary.currency)}` : ''}</h2>
          <div class="card">
            {list.map((e) => {
              const converted = summary?.converted[e.id]
              const row = (
                <>
                  <div class="body"><div class="title">{e.title}</div><div class="meta">{EXPENSE_LABEL[e.category_raw] ?? e.category_raw}</div></div>
                  <div class="end">{money(e.amount, e.currency_code)}{e.currency_code !== trip.currency_code && converted != null && <div class="meta">≈ {money(converted, trip.currency_code)}</div>}</div>
                </>
              )
              return canEdit ? <button class="row trip-row" onClick={() => setEditing(e)}>{row}</button> : <div class="row">{row}</div>
            })}
          </div>
        </>
      ))}
      {editing && <ExpenseDialog data={data} expense={editing === 'new' ? undefined : editing} reload={reload} onClose={() => setEditing(null)} />}
    </>
  )
}

function ExpenseDialog(props: { data: TripData; expense?: Expense; reload: () => Promise<void>; onClose: () => void }) {
  const notify = useNotify()
  const e = props.expense
  const { trip } = props.data
  const today = new Date().toISOString().slice(0, 10)
  const [title, setTitle] = useState(e?.title ?? '')
  const [amount, setAmount] = useState(e ? String(e.amount) : '')
  const [currency, setCurrency] = useState(e?.currency_code ?? trip.currency_code)
  const [category, setCategory] = useState(e?.category_raw ?? 'food')
  const [date, setDate] = useState(e?.date ?? (today >= trip.start_date && today <= trip.end_date ? today : trip.start_date))
  const [busy, setBusy] = useState(false)

  const save = async (event: Event) => {
    event.preventDefault()
    const value = Number(amount.replace(',', '.'))
    if (!Number.isFinite(value)) { notify('Der Betrag ist keine Zahl.', true); return }
    setBusy(true)
    try {
      const data = { title, amount: value, currency_code: currency.toUpperCase(), category_raw: category, date }
      if (e) await api.patch('expense', e.id, data); else await api.createItem(trip.id, 'expense', data)
      await props.reload(); props.onClose()
    } catch (error) { notify(messageOf(error), true); setBusy(false) }
  }
  const remove = async () => {
    setBusy(true)
    try { await api.deleteItem('expense', e!.id); await props.reload(); props.onClose() } catch (error) { notify(messageOf(error), true); setBusy(false) }
  }

  return (
    <Modal title={e ? 'Ausgabe bearbeiten' : 'Ausgabe hinzufügen'} onClose={props.onClose}>
      <form onSubmit={save}>
        <Field label="Wofür"><input value={title} onInput={text(setTitle)} required maxLength={200} /></Field>
        <div class="two">
          <Field label="Betrag"><input inputMode="decimal" value={amount} onInput={text(setAmount)} required /></Field>
          <Field label="Währung">
            <input list="currencies" value={currency} onInput={text(setCurrency)} maxLength={3} required />
            <datalist id="currencies">{CURRENCIES.map((c) => <option value={c} />)}</datalist>
          </Field>
        </div>
        <div class="two">
          <Field label="Art"><select value={category} onChange={(e) => setCategory((e.target as HTMLSelectElement).value)}>{Object.entries(EXPENSE_LABEL).map(([id, label]) => <option value={id}>{label}</option>)}</select></Field>
          <Field label="Datum"><input type="date" value={date} onInput={text(setDate)} required /></Field>
        </div>
        <div class="actions">
          <button class="btn" type="submit" disabled={busy}>{e ? 'Speichern' : 'Hinzufügen'}</button>
          <button class="btn quiet" type="button" onClick={props.onClose}>Abbrechen</button>
          {e && <ConfirmButton label="Löschen" onConfirm={remove} disabled={busy} />}
        </div>
      </form>
    </Modal>
  )
}

// MARK: Bookings

const KIND_LABEL: Record<string, string> = { arrivalFlight: 'Hinflug', departureFlight: 'Rückflug', hotel: 'Hotel' }
const DEFAULT_BUFFER: Record<string, number> = { arrivalFlight: 120, departureFlight: 180, hotel: 0 }

export function Bookings({ data, canEdit, reload }: ViewProps) {
  const [editing, setEditing] = useState<Booking | 'new' | null>(null)
  const sorted = [...data.bookings].sort((a, b) => a.start_date.localeCompare(b.start_date))
  return (
    <>
      {canEdit && <div class="actions"><button class="btn" onClick={() => setEditing('new')}>Buchung hinzufügen</button></div>}
      {sorted.length === 0 && <p class="empty">Noch keine Buchungen. Flüge und Hotels bestimmen, wann ein Tag beginnt und endet.</p>}
      {sorted.length > 0 && (
        <div class="card">
          {sorted.map((b) => {
            const body = (
              <div class="body">
                <div class="title">{b.title} <span class="badge">{KIND_LABEL[b.kind_raw] ?? b.kind_raw}</span></div>
                <div class="meta">{dateTimeLabel(b.start_date)} bis {dateTimeLabel(b.end_date)}</div>
                <div class="meta">{[b.place_name, b.other_end, b.address].filter(Boolean).join(' · ')}</div>
                {b.reference && <div class="meta">Referenz: {b.reference}</div>}
                {b.notes && <div class="meta">{b.notes}</div>}
              </div>
            )
            return canEdit ? <button class="row trip-row" onClick={() => setEditing(b)}>{body}</button> : <div class="row">{body}</div>
          })}
        </div>
      )}
      {editing && <BookingDialog data={data} booking={editing === 'new' ? undefined : editing} reload={reload} onClose={() => setEditing(null)} />}
    </>
  )
}

function BookingDialog(props: { data: TripData; booking?: Booking; reload: () => Promise<void>; onClose: () => void }) {
  const notify = useNotify()
  const b = props.booking
  const { trip } = props.data
  const [kind, setKind] = useState(b?.kind_raw ?? 'hotel')
  const [title, setTitle] = useState(b?.title ?? '')
  const [start, setStart] = useState(b?.start_date ?? `${trip.start_date}T15:00`)
  const [end, setEnd] = useState(b?.end_date ?? `${trip.end_date}T11:00`)
  const [place, setPlace] = useState(b?.place_name ?? '')
  const [other, setOther] = useState(b?.other_end ?? '')
  const [address, setAddress] = useState(b?.address ?? '')
  const [reference, setReference] = useState(b?.reference ?? '')
  const [notes, setNotes] = useState(b?.notes ?? '')
  const [buffer, setBuffer] = useState(String(b?.buffer_minutes ?? DEFAULT_BUFFER[b?.kind_raw ?? 'hotel']))
  const [remind, setRemind] = useState(Boolean(b?.remind))
  const [website, setWebsite] = useState(b?.website ?? '')
  const [position, setPosition] = useState<{ latitude: number; longitude: number } | null>(b?.has_coordinate ? { latitude: b.latitude, longitude: b.longitude } : null)
  const [busy, setBusy] = useState(false)
  const flight = kind !== 'hotel'

  const changeKind = (next: string) => {
    if (!b) { setBuffer(String(DEFAULT_BUFFER[next])); if (next === 'arrivalFlight') setStart(`${trip.start_date}T09:00`) }
    setKind(next)
  }
  const found = (f: FoundPlace) => {
    setPosition({ latitude: f.latitude, longitude: f.longitude })
    if (!place.trim()) setPlace(f.name)
    if (!address.trim()) setAddress(f.address)
  }
  const save = async (event: Event) => {
    event.preventDefault()
    setBusy(true)
    try {
      const data = {
        kind_raw: kind, title, start_date: start.slice(0, 16), end_date: end.slice(0, 16), place_name: place, other_end: other, address, reference, notes,
        buffer_minutes: Math.max(0, Math.round(Number(buffer) || 0)), remind, website, ...(position ?? {}),
      }
      if (b) await api.patch('booking', b.id, data); else await api.createItem(trip.id, 'booking', data)
      await props.reload(); props.onClose()
    } catch (error) { notify(messageOf(error), true); setBusy(false) }
  }
  const remove = async () => {
    setBusy(true)
    try { await api.deleteItem('booking', b!.id); await props.reload(); props.onClose() } catch (error) { notify(messageOf(error), true); setBusy(false) }
  }

  return (
    <Modal title={b ? 'Buchung bearbeiten' : 'Buchung hinzufügen'} onClose={props.onClose}>
      <form onSubmit={save}>
        <Field label="Art">
          <select value={kind} onChange={(e) => changeKind((e.target as HTMLSelectElement).value)}>
            {Object.entries(KIND_LABEL).map(([id, label]) => <option value={id}>{label}</option>)}
          </select>
        </Field>
        <PlaceSearch near={biasOf(props.data)} label={flight ? 'Flughafen suchen (für die Position)' : 'Hotel suchen (für die Position)'} onPick={found} />
        <Field label={flight ? 'Flugnummer' : 'Name des Hotels'}><input value={title} onInput={text(setTitle)} required maxLength={200} /></Field>
        <div class="two">
          <Field label={flight ? 'Abflug / Check-in' : 'Check-in'}><input type="datetime-local" value={start} onInput={text(setStart)} required /></Field>
          <Field label={flight ? 'Landung / Check-out' : 'Check-out'}><input type="datetime-local" value={end} onInput={text(setEnd)} required /></Field>
        </div>
        <Field label={flight ? 'Flughafen' : 'Ort'}><input value={place} onInput={text(setPlace)} maxLength={200} /></Field>
        {flight && <Field label="Gegenseite" hint="Zum Beispiel der Flughafen, von dem oder zu dem du fliegst."><input value={other} onInput={text(setOther)} maxLength={200} /></Field>}
        <Field label="Adresse"><input value={address} onInput={text(setAddress)} maxLength={300} /></Field>
        <div class="two">
          <Field label="Referenz"><input value={reference} onInput={text(setReference)} maxLength={100} /></Field>
          {flight && <Field label="Puffer (Minuten)" hint={kind === 'arrivalFlight' ? 'Zeit nach der Landung, bis der Tag beginnt.' : 'Zeit vor dem Abflug für den Weg zum Flughafen.'}><input inputMode="numeric" value={buffer} onInput={text(setBuffer)} /></Field>}
        </div>
        <Field label="Webseite"><input type="url" value={website} onInput={text(setWebsite)} placeholder="https://…" /></Field>
        <Field label="Notizen"><textarea rows={3} value={notes} onInput={text(setNotes)} /></Field>
        <label class="check"><input type="checkbox" checked={remind} onChange={(e) => setRemind((e.target as HTMLInputElement).checked)} /> Erinnerung (wird in der App verwendet)</label>
        <p class="note">{position ? `Position gesetzt (${position.latitude.toFixed(4)}, ${position.longitude.toFixed(4)}).` : 'Ohne Position kann ein Hotel nicht Startpunkt der Tage sein und die Buchung nicht in den Plan gelegt werden.'}</p>
        <div class="actions">
          <button class="btn" type="submit" disabled={busy}>{b ? 'Speichern' : 'Hinzufügen'}</button>
          <button class="btn quiet" type="button" onClick={props.onClose}>Abbrechen</button>
          {b && <ConfirmButton label="Löschen" onConfirm={remove} disabled={busy} />}
        </div>
      </form>
    </Modal>
  )
}

// MARK: Packing list

export function Packing({ data, canEdit, reload, mutate }: ViewProps) {
  const notify = useNotify()
  const run = useOperation(reload)
  const [title, setTitle] = useState('')
  const [section, setSection] = useState('')
  const [dialog, setDialog] = useState(false)
  const sections = [...new Set(data.checklist.map((c) => c.section))]

  const tick = async (id: string, checked: boolean) => {
    mutate((d) => ({ ...d, checklist: d.checklist.map((c) => (c.id === id ? { ...c, is_done: checked } : c)) }))
    try { await api.patch('checklist_item', id, { is_done: checked }) } catch (error) { notify(messageOf(error), true) }
    await reload()
  }
  const add = async (event: Event) => {
    event.preventDefault()
    try { await api.createItem(data.trip.id, 'checklist_item', { title, section }); setTitle(''); await reload() } catch (error) { notify(messageOf(error), true) }
  }
  const done = data.checklist.filter((c) => c.is_done).length

  return (
    <>
      {canEdit && (
        <>
          <form class="two add-item" onSubmit={add}>
            <input value={title} onInput={text(setTitle)} placeholder="Neuer Eintrag" aria-label="Neuer Eintrag" required maxLength={200} />
            <input list="sections" value={section} onInput={text(setSection)} placeholder="Bereich" aria-label="Bereich" maxLength={100} />
            <datalist id="sections">{sections.filter(Boolean).map((s) => <option value={s} />)}</datalist>
            <button class="btn" type="submit">Hinzufügen</button>
          </form>
          <div class="actions">
            <button class="btn secondary" onClick={() => setDialog(true)}>Vorschläge hinzufügen</button>
            {done > 0 && <button class="btn quiet" onClick={() => run('Alle Haken entfernt', () => api.packingReset(data.trip.id))}>Haken zurücksetzen</button>}
            {data.checklist.length > 0 && <button class="btn quiet" onClick={() => run('Packliste geleert', () => api.packingClear(data.trip.id))}>Liste leeren</button>}
          </div>
        </>
      )}
      {data.checklist.length === 0 ? <div class="empty"><p>Die Packliste ist leer.</p>{canEdit && <button class="btn secondary" onClick={() => setDialog(true)}>Vorschläge hinzufügen</button>}</div> : <p class="note">{done} von {data.checklist.length} erledigt</p>}
      {sections.map((name) => (
        <>
          {name && <h2>{name}</h2>}
          <div class="card">
            {data.checklist.filter((c) => c.section === name).map((c: ChecklistItem) => (
              <div class={`row${c.is_done ? ' done' : ''}`}>
                <label class="check">
                  <input type="checkbox" class="tick" checked={c.is_done} disabled={!canEdit} onChange={(e) => tick(c.id, (e.target as HTMLInputElement).checked)} />
                  <span class="title">{c.title}</span>
                </label>
                {canEdit && <button class="btn quiet" aria-label={`${c.title} entfernen`} onClick={() => run('Eintrag entfernt', () => api.deleteItem('checklist_item', c.id))}>×</button>}
              </div>
            ))}
          </div>
        </>
      ))}
      {dialog && <TemplateDialog tripId={data.trip.id} run={run} onClose={() => setDialog(false)} />}
    </>
  )
}

function TemplateDialog(props: { tripId: string; run: ReturnType<typeof useOperation>; onClose: () => void }) {
  const [climate, setClimate] = useState('mild')
  const [nights, setNights] = useState('3')
  const [flags, setFlags] = useState<Record<string, boolean>>({ rain: false, beach: false, hiking: false, business: false, nightlife: false, kids: false })
  const labels: Record<string, string> = { rain: 'Regen möglich', beach: 'Strand', hiking: 'Wandern', business: 'Geschäftlich', nightlife: 'Abends ausgehen', kids: 'Mit Kindern' }
  const go = async (event: Event) => {
    event.preventDefault()
    const done = await props.run('Vorschläge hinzugefügt', () => api.packingTemplate(props.tripId, { climate, nights: Math.max(0, Math.round(Number(nights) || 0)), ...flags }))
    if (done) props.onClose()
  }
  return (
    <Modal title="Packliste vorschlagen" onClose={props.onClose}>
      <form onSubmit={go}>
        <p class="note">Es kommen nur Einträge dazu, die noch nicht auf der Liste stehen. Alles lässt sich danach ändern.</p>
        <div class="two">
          <Field label="Klima"><select value={climate} onChange={(e) => setClimate((e.target as HTMLSelectElement).value)}><option value="warm">Warm</option><option value="mild">Mild</option><option value="cold">Kalt</option></select></Field>
          <Field label="Nächte"><input inputMode="numeric" value={nights} onInput={text(setNights)} /></Field>
        </div>
        {Object.entries(labels).map(([key, label]) => (
          <label class="check"><input type="checkbox" checked={flags[key]} onChange={(e) => setFlags({ ...flags, [key]: (e.target as HTMLInputElement).checked })} /> {label}</label>
        ))}
        <div class="actions"><button class="btn" type="submit">Hinzufügen</button><button class="btn quiet" type="button" onClick={props.onClose}>Abbrechen</button></div>
      </form>
    </Modal>
  )
}

