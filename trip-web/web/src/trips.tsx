import { useEffect, useState } from 'preact/hooks'
import { api, type TripFields } from './api'
import { shortDate } from './format'
import type { ImportPreview, Member, Person, Phase, Role, Trip, TripSummary } from './types'
import { Field, Modal, messageOf, useNotify } from './ui'

const ROLE_LABEL: Record<Role, string> = { owner: 'Besitzer', editor: 'Bearbeiter', viewer: 'Betrachter' }
const count = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`
const ZONES = ['Europe/Zurich', 'Europe/Berlin', 'Europe/Vienna', 'Europe/Warsaw', 'Europe/London', 'Europe/Paris', 'Europe/Rome', 'America/New_York', 'Asia/Tokyo']

function ZoneInput(props: { value: string; onInput: (value: string) => void; id: string }) {
  return (
    <>
      <input list={props.id} value={props.value} onInput={(event) => props.onInput((event.target as HTMLInputElement).value)} autocomplete="off" />
      <datalist id={props.id}>{ZONES.map((zone) => <option value={zone} />)}</datalist>
    </>
  )
}

// MARK: List of trips

export function TripList(props: { trips: TripSummary[]; onOpen: (id: string) => void; onChanged: (openId?: string) => void }) {
  const [dialog, setDialog] = useState<'new' | 'import' | null>(null)
  const sorted = [...props.trips].sort((a, b) => a.start_date.localeCompare(b.start_date))
  const today = new Date().toISOString().slice(0, 10)
  const upcoming = sorted.filter((t) => t.end_date >= today)
  const past = sorted.filter((t) => t.end_date < today).reverse()

  const group = (title: string, list: TripSummary[]) => list.length > 0 && (
    <>
      <h2>{title}</h2>
      <div class="card">
        {list.map((trip) => (
          <button class="row trip-row" onClick={() => props.onOpen(trip.id)}>
            <div class="body">
              <div class="title">{trip.name}</div>
              <div class="meta">{[trip.destination, `${shortDate(trip.start_date)} bis ${shortDate(trip.end_date)} ${trip.end_date.slice(0, 4)}`].filter(Boolean).join(' · ')}</div>
            </div>
            <span class={`badge phase ${trip.phase}`}>{PHASE_LABEL[trip.phase]}</span>
            <span class="badge">{ROLE_LABEL[trip.role]}</span>
          </button>
        ))}
      </div>
    </>
  )

  return (
    <>
      <header class="header">
        <h1>Meine Reisen</h1>
        <div class="actions">
          <button class="btn" onClick={() => setDialog('new')}>Neue Reise</button>
          <button class="btn secondary" onClick={() => setDialog('import')}>Aus der App importieren</button>
        </div>
      </header>
      {props.trips.length === 0 && <p class="empty">Noch keine Reise. Lege eine an oder hole eine Reise aus der App mit einer .tripplanner-Datei.</p>}
      {group('Bevorstehend', upcoming)}
      {group('Vergangen', past)}
      {dialog === 'new' && <TripForm onClose={() => setDialog(null)} onSaved={(id) => { setDialog(null); props.onChanged(id) }} />}
      {dialog === 'import' && <ImportDialog onClose={() => setDialog(null)} onDone={(id) => { setDialog(null); props.onChanged(id) }} />}
    </>
  )
}

// MARK: Create and edit

export function TripForm(props: { trip?: Trip; onClose: () => void; onSaved: (id: string) => void }) {
  const notify = useNotify()
  const t = props.trip
  const [name, setName] = useState(t?.name ?? '')
  const [destination, setDestination] = useState(t?.destination ?? '')
  const [start, setStart] = useState(t?.start_date ?? '')
  const [end, setEnd] = useState(t?.end_date ?? '')
  const [currency, setCurrency] = useState(t?.currency_code ?? 'CHF')
  const [budget, setBudget] = useState(String(t?.budget ?? 0))
  const [transport, setTransport] = useState<Trip['transport_raw']>(t?.transport_raw ?? 'walking')
  const [phase, setPhase] = useState<Phase>(t?.phase ?? 'planning')
  const [travelers, setTravelers] = useState(String(t?.travelers ?? 1))
  const [busy, setBusy] = useState(false)

  const submit = async (event: Event) => {
    event.preventDefault()
    const fields: TripFields = {
      name, destination, start_date: start, end_date: end, currency_code: currency.toUpperCase(),
      budget: Number(budget.replace(',', '.')) || 0, transport_raw: transport, travelers: Math.max(1, Math.round(Number(travelers) || 1)),
      ...(t ? {} : { phase }),
    }
    setBusy(true)
    try {
      if (t) { await api.updateTrip(t.id, fields); props.onSaved(t.id) }
      else props.onSaved((await api.createTrip(fields)).trip_id)
    } catch (error) {
      notify(messageOf(error), true)
      setBusy(false)
    }
  }

  return (
    <Modal title={t ? 'Reise bearbeiten' : 'Neue Reise'} onClose={props.onClose}>
      <form onSubmit={submit}>
        <Field label="Name"><input value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} required maxLength={100} /></Field>
        <Field label="Ziel"><input value={destination} onInput={(e) => setDestination((e.target as HTMLInputElement).value)} maxLength={100} /></Field>
        <div class="two">
          <Field label="Von"><input type="date" value={start} onInput={(e) => setStart((e.target as HTMLInputElement).value)} required /></Field>
          <Field label="Bis"><input type="date" value={end} min={start} onInput={(e) => setEnd((e.target as HTMLInputElement).value)} required /></Field>
        </div>
        <div class="two">
          <Field label="Währung"><input value={currency} onInput={(e) => setCurrency((e.target as HTMLInputElement).value)} maxLength={3} required /></Field>
          <Field label="Budget"><input inputMode="decimal" value={budget} onInput={(e) => setBudget((e.target as HTMLInputElement).value)} /></Field>
        </div>
        <Field label="Reisende" hint="Fahrpreise sind pro Person; damit wird der Preis für alle ausgerechnet."><input inputMode="numeric" value={travelers} onInput={(e) => setTravelers((e.target as HTMLInputElement).value)} /></Field>
        <Field label="Unterwegs meistens">
          <select value={transport} onChange={(e) => setTransport((e.target as HTMLSelectElement).value as Trip['transport_raw'])}>
            <option value="walking">zu Fuss</option>
            <option value="transit">öffentlicher Verkehr</option>
            <option value="car">Auto</option>
          </select>
        </Field>
        {!t && (
          <Field label="Wo steht die Reise?" hint="In der Planungsphase sammelt ihr Ideen und entscheidet. Die Aufbauphase baut Tag für Tag auf, wie die App.">
            <select value={phase} onChange={(e) => setPhase((e.target as HTMLSelectElement).value as Phase)}>
              <option value="planning">Ich sammle noch Ideen (Planungsphase)</option>
              <option value="building">Ich plane schon Tag für Tag (Aufbauphase)</option>
            </select>
          </Field>
        )}
        {t && <p class="note">Wenn du die Daten änderst, kommen Tage dazu oder fallen weg. Tage mit Stopps bleiben immer erhalten.</p>}
        <div class="actions">
          <button class="btn" type="submit" disabled={busy}>{t ? 'Speichern' : 'Anlegen'}</button>
          <button class="btn quiet" type="button" onClick={props.onClose}>Abbrechen</button>
        </div>
      </form>
    </Modal>
  )
}

// MARK: Sharing

export function ShareDialog(props: { trip: Trip; members: Member[]; isOwner: boolean; onClose: () => void; onChanged: () => void }) {
  const notify = useNotify()
  const [query, setQuery] = useState('')
  const [found, setFound] = useState<Person[]>([])
  const [role, setRole] = useState<Role>('editor')

  useEffect(() => {
    if (!props.isOwner || query.trim().length < 2) { setFound([]); return }
    const timer = window.setTimeout(() => {
      api.people(query).then((list) => setFound(list.filter((p) => !props.members.some((m) => m.sub === p.sub)))).catch((e) => notify(messageOf(e), true))
    }, 250)
    return () => window.clearTimeout(timer)
  }, [query, props.members])

  const run = async (action: () => Promise<unknown>, done: string) => {
    try { await action(); notify(done); props.onChanged() } catch (error) { notify(messageOf(error), true) }
  }

  return (
    <Modal title="Reise teilen" onClose={props.onClose}>
      <p class="note">Mitglieder sehen „{props.trip.name}“. Betrachter können nur lesen, Bearbeiter ändern den Plan, Besitzer teilen und löschen.</p>
      <div class="card">
        {props.members.map((member) => (
          <div class="row">
            <div class="body"><div class="title">{member.name || 'Unbekannt'}</div><div class="meta">{member.username}</div></div>
            {props.isOwner && member.sub ? (
              <>
                <select aria-label={`Rolle von ${member.name}`} value={member.role}
                  onChange={(e) => run(() => api.setMember(props.trip.id, member.sub!, (e.target as HTMLSelectElement).value as Role), 'Rolle geändert')}>
                  {(Object.keys(ROLE_LABEL) as Role[]).map((r) => <option value={r}>{ROLE_LABEL[r]}</option>)}
                </select>
                <button class="btn quiet" onClick={() => run(() => api.removeMember(props.trip.id, member.sub!), 'Entfernt')}>Entfernen</button>
              </>
            ) : <span class="badge">{ROLE_LABEL[member.role]}</span>}
          </div>
        ))}
      </div>
      {props.isOwner ? (
        <>
          <h3>Person hinzufügen</h3>
          <p class="note">Gesucht werden Leute, die sich schon einmal auf dieser Website angemeldet haben.</p>
          <div class="two">
            <input type="search" placeholder="Name oder Benutzername" aria-label="Person suchen" value={query} onInput={(e) => setQuery((e.target as HTMLInputElement).value)} />
            <select aria-label="Rolle" value={role} onChange={(e) => setRole((e.target as HTMLSelectElement).value as Role)}>
              {(Object.keys(ROLE_LABEL) as Role[]).map((r) => <option value={r}>{ROLE_LABEL[r]}</option>)}
            </select>
          </div>
          {found.map((person) => (
            <div class="row">
              <div class="body"><div class="title">{person.name}</div><div class="meta">{person.username}</div></div>
              <button class="btn" onClick={() => run(() => api.setMember(props.trip.id, person.sub, role), `${person.name} hinzugefügt`)}>Hinzufügen</button>
            </div>
          ))}
          {query.trim().length >= 2 && found.length === 0 && <p class="empty">Niemand gefunden.</p>}
        </>
      ) : <p class="note">Nur Besitzer können die Mitglieder ändern.</p>}
      <div class="actions"><button class="btn quiet" onClick={props.onClose}>Schliessen</button></div>
    </Modal>
  )
}

// MARK: Import from the app

export function ImportDialog(props: { onClose: () => void; onDone: (openId?: string) => void }) {
  const notify = useNotify()
  const [archive, setArchive] = useState<unknown>(null)
  const [fileName, setFileName] = useState('')
  const [zone, setZone] = useState('Europe/Zurich')
  const [preview, setPreview] = useState<ImportPreview | null>(null)
  const [busy, setBusy] = useState(false)

  const read = async (file: File | undefined) => {
    setPreview(null)
    if (!file) return
    setFileName(file.name)
    try { setArchive(JSON.parse(await file.text())) } catch { setArchive(null); notify('Diese Datei lässt sich nicht lesen. Ist es eine .tripplanner-Datei?', true) }
  }

  useEffect(() => {
    if (!archive) return
    const timer = window.setTimeout(() => {
      api.importPreview(archive, zone).then(setPreview).catch((e) => { setPreview(null); notify(messageOf(e), true) })
    }, 300)
    return () => window.clearTimeout(timer)
  }, [archive, zone])

  const run = async () => {
    setBusy(true)
    try {
      const done = await api.importTrips(archive, zone)
      notify(`${done.trips.length} Reise(n) importiert`)
      props.onDone(done.trips.length === 1 ? done.trips[0].trip_id : undefined)
    } catch (error) { notify(messageOf(error), true); setBusy(false) }
  }

  return (
    <Modal title="Reise aus der App importieren" onClose={props.onClose}>
      <p class="note">In der App: Reise öffnen, Teilen, „.tripplanner“-Datei sichern, und hier auswählen. Die Datei enthält deine Reisedaten, bewahre sie nicht öffentlich auf.</p>
      <Field label="Datei"><input type="file" accept=".tripplanner,application/json,.json" onChange={(e) => read((e.target as HTMLInputElement).files?.[0])} /></Field>
      <Field label="Zeitzone deines iPhones beim Planen" hint="Die App speichert Zeitpunkte ohne Zeitzone. Damit werden sie in Uhrzeiten vor Ort zurückgerechnet. Prüfe unten, ob die Zeiten stimmen.">
        <ZoneInput id="import-zones" value={zone} onInput={setZone} />
      </Field>
      {preview && preview.trips.map((trip) => (
        <div class="card">
          <div class="row"><div class="body">
            <div class="title">{trip.name}</div>
            <div class="meta">{shortDate(trip.start_date)} bis {shortDate(trip.end_date)} {trip.end_date.slice(0, 4)}</div>
            <div class="meta">{[
              count(trip.stops, 'Stopp', 'Stopps') + (trip.stops > 0 ? ` an ${count(trip.days_with_stops, 'Tag', 'Tagen')}` : ''),
              count(trip.expenses, 'Ausgabe', 'Ausgaben'), count(trip.bookings, 'Buchung', 'Buchungen'),
              count(trip.checklist, 'Packlisten-Eintrag', 'Packlisten-Einträge'), count(trip.places, 'gespeicherter Ort', 'gespeicherte Orte'),
            ].join(' · ')}</div>
            {trip.documents_skipped > 0 && <div class="meta">{count(trip.documents_skipped, 'Dokument wird', 'Dokumente werden')} nicht übernommen.</div>}
            {trip.sample.length > 0 && (
              <div class="meta">Erste Zeiten: {trip.sample.map((s) => `${shortDate(s.date)} ${s.time} ${s.name}`).join(' · ')}</div>
            )}
          </div></div>
        </div>
      ))}
      <div class="actions">
        <button class="btn" disabled={!preview || busy} onClick={run}>Importieren</button>
        <button class="btn quiet" onClick={props.onClose}>Abbrechen</button>
      </div>
      {fileName && !preview && archive !== null && <p class="note" role="status">Prüfe {fileName} …</p>}
    </Modal>
  )
}

// MARK: Export and delete

export function ExportDialog(props: { trip: Trip; onClose: () => void }) {
  const [phoneZone, setPhoneZone] = useState('Europe/Zurich')
  const [tripZone, setTripZone] = useState(props.trip.time_zone || 'Europe/Zurich')
  return (
    <Modal title="Exportieren" onClose={props.onClose}>
      <h3>Für die App</h3>
      <p class="note">Die Datei lässt sich in der App öffnen (sie legt eine Kopie der Reise an). Fotos, Dokumente und Hinweise der App sind nicht enthalten.</p>
      <Field label="Zeitzone deines iPhones" hint="Die App rechnet die Uhrzeiten mit der Zeitzone des Geräts. Meistens ist es die deines Wohnorts.">
        <ZoneInput id="export-zones" value={phoneZone} onInput={setPhoneZone} />
      </Field>
      <div class="actions"><a class="btn" href={api.exportUrl(props.trip.id, phoneZone)} download>.tripplanner-Datei laden</a></div>
      <h3>Kalender</h3>
      <p class="note">Alle Stopps mit Uhrzeit sowie Flüge und Hotels, zum Importieren in einen Kalender. Ein erneuter Import aktualisiert die Einträge.</p>
      <Field label="Zeitzone am Reiseziel"><ZoneInput id="export-zones-trip" value={tripZone} onInput={setTripZone} /></Field>
      <div class="actions"><a class="btn secondary" href={api.exportIcsUrl(props.trip.id, tripZone)} download>Kalenderdatei laden</a></div>
      <h3>Text</h3>
      <p class="note">Der Reiseplan als einfacher Text zum Teilen.</p>
      <div class="actions"><a class="btn secondary" href={api.exportTextUrl(props.trip.id)} download>Text laden</a></div>
      <div class="actions"><button class="btn quiet" onClick={props.onClose}>Schliessen</button></div>
    </Modal>
  )
}

export function DeleteDialog(props: { trip: Trip; onClose: () => void; onDeleted: () => void }) {
  const notify = useNotify()
  const [busy, setBusy] = useState(false)
  const run = async () => {
    setBusy(true)
    try { await api.deleteTrip(props.trip.id); notify('Reise gelöscht'); props.onDeleted() } catch (error) { notify(messageOf(error), true); setBusy(false) }
  }
  return (
    <Modal title="Reise löschen?" onClose={props.onClose}>
      <p>„{props.trip.name}“ verschwindet für alle Mitglieder. Die Daten bleiben auf dem Server, lassen sich aber nur über den Administrator zurückholen.</p>
      <div class="actions">
        <button class="btn danger" disabled={busy} onClick={run}>Löschen</button>
        <button class="btn quiet" onClick={props.onClose}>Abbrechen</button>
      </div>
    </Modal>
  )
}

// MARK: Phases

export const PHASE_LABEL: Record<Phase, string> = { planning: 'Planungsphase', building: 'Aufbauphase' }

export function PhaseDialog(props: { trip: Trip; to: Phase; onClose: () => void; onSaved: () => Promise<void> }) {
  const notify = useNotify()
  const [start, setStart] = useState(props.trip.start_date)
  const [end, setEnd] = useState(props.trip.end_date)
  const [busy, setBusy] = useState(false)
  const building = props.to === 'building'

  const submit = async (event: Event) => {
    event.preventDefault()
    setBusy(true)
    try {
      await api.updateTrip(props.trip.id, building ? { phase: 'building', start_date: start, end_date: end } : { phase: 'planning' })
      notify(building ? 'Aufbauphase gestartet' : 'Zurück in der Planungsphase')
      await props.onSaved()
      props.onClose()
    } catch (error) { notify(messageOf(error), true); setBusy(false) }
  }

  return (
    <Modal title={building ? 'Aufbauphase starten' : 'Zurück in die Planungsphase'} onClose={props.onClose}>
      <form onSubmit={submit}>
        {building ? (
          <>
            <p>In der Aufbauphase baust du die Reise Tag für Tag auf, wie in der App: Tagesplan, Buchungen, Budget und Packliste. Die Ideen und Entscheide bleiben erhalten.</p>
            <p class="note">Lege jetzt die genauen Reisedaten fest, wenn sie feststehen (zum Beispiel nach der Flugbuchung). Daraus entstehen die Tage. Du kannst sie später ändern.</p>
            <div class="two">
              <Field label="Hinreise (erster Tag)"><input type="date" value={start} onInput={(e) => setStart((e.target as HTMLInputElement).value)} required /></Field>
              <Field label="Rückreise (letzter Tag)"><input type="date" value={end} min={start} onInput={(e) => setEnd((e.target as HTMLInputElement).value)} required /></Field>
            </div>
          </>
        ) : (
          <p>Der Tagesplan, die Buchungen, das Budget und die Packliste bleiben gespeichert, werden aber ausgeblendet, bis du die Aufbauphase wieder startest. Claude kann sie weiterhin sehen.</p>
        )}
        <div class="actions">
          <button class="btn" type="submit" disabled={busy}>{building ? 'Aufbauphase starten' : 'Zurück zur Planung'}</button>
          <button class="btn quiet" type="button" onClick={props.onClose}>Abbrechen</button>
        </div>
      </form>
    </Modal>
  )
}
