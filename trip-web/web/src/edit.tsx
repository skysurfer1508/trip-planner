import { useEffect, useState } from 'preact/hooks'
import { api } from './api'
import { safeUrl } from './format'
import { CATEGORIES } from './categories'
import { PRIOS, VERDICTS } from './filters'
import type { Decision, FoundPlace, Place, Prio, TripData, Verdict } from './types'
import { Field, Modal, messageOf, useNotify } from './ui'

const input = (set: (value: string) => void) => (event: Event) => set((event.target as HTMLInputElement | HTMLTextAreaElement).value)

/** Where to look first: the trip's destination, else the middle of the places that already have a position. */
export function biasOf(data: TripData): [number, number] | undefined {
  const { trip, places, stops } = data
  if (trip.destination_latitude && trip.destination_longitude) return [trip.destination_latitude, trip.destination_longitude]
  const known = [...places, ...stops].filter((p) => p.latitude && p.longitude)
  if (known.length === 0) return undefined
  return [known.reduce((a, p) => a + p.latitude!, 0) / known.length, known.reduce((a, p) => a + p.longitude!, 0) / known.length]
}

/** A search box over OpenStreetMap places. Picking a result hands it to the parent. */
export function PlaceSearch(props: { near?: [number, number]; label?: string; onPick: (found: FoundPlace) => void }) {
  const notify = useNotify()
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<FoundPlace[]>([])
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (query.trim().length < 2) { setResults([]); return }
    setBusy(true)
    const timer = window.setTimeout(() => {
      api.searchPlaces(query, props.near).then(setResults).catch((e) => { setResults([]); notify(messageOf(e), true) }).finally(() => setBusy(false))
    }, 400)
    return () => window.clearTimeout(timer)
  }, [query])

  return (
    <div class="search">
      <Field label={props.label ?? 'Ort suchen'}>
        <input type="search" value={query} placeholder="z. B. Senso-ji" onInput={input(setQuery)} autocomplete="off" />
      </Field>
      {busy && <p class="note" role="status">Suche …</p>}
      {results.length > 0 && (
        <div class="card results">
          {results.map((r) => (
            <button type="button" class="row trip-row" onClick={() => { props.onPick(r); setQuery(''); setResults([]) }}>
              <div class="body"><div class="title">{r.name}</div><div class="meta">{r.address}</div></div>
            </button>
          ))}
        </div>
      )}
      {!busy && query.trim().length >= 2 && results.length === 0 && <p class="note">Nichts gefunden.</p>}
    </div>
  )
}

// MARK: Ideas

export function PlaceDialog(props: { tripId: string; place?: Place; regions?: string[]; near?: [number, number]; onClose: () => void; onSaved: () => Promise<void> }) {
  const notify = useNotify()
  const p = props.place
  const [name, setName] = useState(p?.name ?? '')
  const [region, setRegion] = useState(p?.region ?? '')
  const [category, setCategory] = useState(p?.category ?? '')
  const [description, setDescription] = useState(p?.description ?? '')
  const [duration, setDuration] = useState(p?.duration ?? '')
  const [heat, setHeat] = useState(p?.heat ?? '')
  const [forWhom, setForWhom] = useState(p?.for_whom ?? '')
  const [wishedBy, setWishedBy] = useState(p?.wished_by ?? '')
  const [notes, setNotes] = useState(p?.notes ?? '')
  const [website, setWebsite] = useState(p?.website ?? '')
  const [prio, setPrio] = useState<Prio>(p?.prio ?? 'Gerne')
  const [decision, setDecision] = useState<Verdict>(p?.decision ?? 'Offen')
  const [position, setPosition] = useState<{ latitude: number; longitude: number } | null>(p?.has_coordinate ? { latitude: p.latitude, longitude: p.longitude } : null)
  const [busy, setBusy] = useState(false)

  const pick = (found: FoundPlace) => {
    if (!name.trim()) setName(found.name)
    if (!description.trim() && found.address) setDescription(found.address)
    setPosition({ latitude: found.latitude, longitude: found.longitude })
  }

  const submit = async (event: Event) => {
    event.preventDefault()
    const data: Record<string, unknown> = {
      name, region, description, duration, heat, for_whom: forWhom, wished_by: wishedBy, notes, website, prio, decision,
      ...(category ? { category } : {}), ...(position ? position : {}),
    }
    setBusy(true)
    try {
      if (p) await api.patch('place', p.id, data)
      else await api.createItem(props.tripId, 'place', { ...data, source: 'Website' })
      await props.onSaved()
      props.onClose()
    } catch (error) { notify(messageOf(error), true); setBusy(false) }
  }

  return (
    <Modal title={p ? 'Ort bearbeiten' : 'Ort hinzufügen'} onClose={props.onClose}>
      <form onSubmit={submit}>
        <PlaceSearch near={props.near} label={p ? 'Position neu suchen' : 'Ort suchen und übernehmen'} onPick={pick} />
        <Field label="Name"><input value={name} onInput={input(setName)} required maxLength={200} /></Field>
        <datalist id="regions">{(props.regions ?? []).map((r) => <option value={r} />)}</datalist>
        <div class="two">
          <Field label="Region" hint="Stadt, Gebiet oder Berge"><input value={region} onInput={input(setRegion)} list="regions" maxLength={100} /></Field>
          <Field label="Kategorie">
            <select value={category} onChange={(e) => setCategory((e.target as HTMLSelectElement).value)}>
              {!p && <option value="">Automatisch</option>}
              {CATEGORIES.map((c) => <option value={c.id}>{c.label}</option>)}
            </select>
          </Field>
        </div>
        <Field label="Dauer"><input value={duration} onInput={input(setDuration)} placeholder="½ Tag, 1 Tag, Abend …" maxLength={100} /></Field>
        <Field label="Beschreibung"><textarea rows={3} value={description} onInput={input(setDescription)} /></Field>
        <div class="two">
          <Field label="Hitze / beste Zeit"><input value={heat} onInput={input(setHeat)} maxLength={200} /></Field>
          <Field label="Für wen"><input value={forWhom} onInput={input(setForWhom)} maxLength={100} /></Field>
        </div>
        <div class="two">
          <Field label="Wunsch von"><input value={wishedBy} onInput={input(setWishedBy)} maxLength={100} /></Field>
          <Field label="Webseite"><input type="url" value={website} onInput={input(setWebsite)} placeholder="https://…" /></Field>
        </div>
        <Field label="Notizen"><textarea rows={2} value={notes} onInput={input(setNotes)} /></Field>
        <div class="two">
          <Field label="Priorität">
            <select value={prio} onChange={(e) => setPrio((e.target as HTMLSelectElement).value as Prio)}>{PRIOS.map((x) => <option>{x}</option>)}</select>
          </Field>
          <Field label="Entscheid">
            <select value={decision} onChange={(e) => setDecision((e.target as HTMLSelectElement).value as Verdict)}>{VERDICTS.map((x) => <option>{x}</option>)}</select>
          </Field>
        </div>
        <p class="note">{position ? `Position gesetzt (${position.latitude.toFixed(4)}, ${position.longitude.toFixed(4)}), der Ort erscheint auf der Karte.` : 'Ohne Position erscheint der Ort nur in der Liste. Such ihn oben, um ihn auf die Karte zu bringen.'}</p>
        <div class="actions">
          <button class="btn" type="submit" disabled={busy}>{p ? 'Speichern' : 'Hinzufügen'}</button>
          <button class="btn quiet" type="button" onClick={props.onClose}>Abbrechen</button>
        </div>
      </form>
    </Modal>
  )
}

// MARK: Decisions

export function DecisionDialog(props: { tripId: string; decision?: Decision; onClose: () => void; onSaved: () => Promise<void> }) {
  const notify = useNotify()
  const d = props.decision
  const [title, setTitle] = useState(d?.title ?? '')
  const [detail, setDetail] = useState(d?.detail ?? '')
  const [kind, setKind] = useState<Decision['kind']>(d?.kind ?? 'open')
  const [busy, setBusy] = useState(false)

  const submit = async (event: Event) => {
    event.preventDefault()
    setBusy(true)
    try {
      if (d) await api.patch('decision', d.id, { title, detail, kind })
      else await api.createItem(props.tripId, 'decision', { title, detail, kind })
      await props.onSaved()
      props.onClose()
    } catch (error) { notify(messageOf(error), true); setBusy(false) }
  }
  const remove = async () => {
    setBusy(true)
    try { await api.deleteItem('decision', d!.id); await props.onSaved(); props.onClose() } catch (error) { notify(messageOf(error), true); setBusy(false) }
  }

  return (
    <Modal title={d ? 'Entscheid bearbeiten' : 'Entscheid oder offene Frage'} onClose={props.onClose}>
      <form onSubmit={submit}>
        <Field label="Titel"><input value={title} onInput={input(setTitle)} required maxLength={200} /></Field>
        <Field label="Details"><textarea rows={4} value={detail} onInput={input(setDetail)} /></Field>
        <Field label="Stand">
          <select value={kind} onChange={(e) => setKind((e.target as HTMLSelectElement).value as Decision['kind'])}>
            <option value="open">Noch offen</option>
            <option value="decided">Entschieden</option>
          </select>
        </Field>
        <div class="actions">
          <button class="btn" type="submit" disabled={busy}>{d ? 'Speichern' : 'Hinzufügen'}</button>
          <button class="btn quiet" type="button" onClick={props.onClose}>Abbrechen</button>
          {d && <button class="btn quiet" type="button" onClick={remove} disabled={busy}>Löschen</button>}
        </div>
      </form>
    </Modal>
  )
}

export { safeUrl }
