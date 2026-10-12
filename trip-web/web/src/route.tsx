import L from 'leaflet'
import { useEffect, useRef, useState } from 'preact/hooks'
import { api } from './api'
import { biasOf, PlaceSearch } from './edit'
import { dateTimeLabel, money, safeUrl } from './format'
import { MapFrame, useLeafletMap } from './map'
import { MODES, duration, modeColor, modeLabel } from './modes'
import { useOperation } from './plan'
import { categoryLabel } from './categories'
import type { FoundPlace, Leg, LegView, PassComparison, Place as IdeaPlace, RouteSummary, TripData } from './types'
import { Field, Modal, Skeleton, messageOf, useNotify, ConfirmButton } from './ui'
import type { ViewProps } from './views'

const STATUS_LABEL = { option: 'Option', chosen: 'Gewählt', booked: 'Gebucht' } as const

// MARK: The map

const DASH: Record<string, string | undefined> = { flight: '2 10', bus: '10 6', walk: '2 6', ferry: '12 6' }
const GLYPH: Record<string, string> = { shinkansen: '🚄', train: '🚆', bus: '🚌', flight: '✈️', ferry: '⛴️', car: '🚗', taxi: '🚕', walk: '🚶', other: '•' }
const modeGlyph = (mode: string) => GLYPH[mode] ?? '•'

/** The point `f` (0..1) of the way along a line, measured by length so it also works for lines with uneven point spacing. */
function along(path: [number, number][], f: number): [number, number] {
  const lengths = path.slice(1).map((p, i) => Math.hypot(p[0] - path[i][0], (p[1] - path[i][1]) * Math.cos((p[0] * Math.PI) / 180)))
  let left = lengths.reduce((a, b) => a + b, 0) * f
  for (let i = 0; i < lengths.length; i++) {
    if (left <= lengths[i] || i === lengths.length - 1) {
      const t = lengths[i] ? Math.min(1, left / lengths[i]) : 0
      return [path[i][0] + (path[i + 1][0] - path[i][0]) * t, path[i][1] + (path[i + 1][1] - path[i][1]) * t]
    }
    left -= lengths[i]
  }
  return path[0]
}

/** A gentle arc between two places (quadratic curve), so overlapping ways and the direction stay readable. `bend` is the sideways offset as a share of the distance. */
function curve(a: [number, number], b: [number, number], bend: number, steps = 24): [number, number][] {
  const mid: [number, number] = [(a[0] + b[0]) / 2 - (b[1] - a[1]) * bend, (a[1] + b[1]) / 2 + (b[0] - a[0]) * bend]
  return Array.from({ length: steps + 1 }, (_, i) => {
    const t = i / steps, u = 1 - t
    return [u * u * a[0] + 2 * u * t * mid[0] + t * t * b[0], u * u * a[1] + 2 * u * t * mid[1] + t * t * b[1]] as [number, number]
  })
}

function RouteMap(props: { places?: IdeaPlace[]; summary: RouteSummary; selectedHop: number | null; expanded: boolean; onExpand: (v: boolean) => void }) {
  const { element, map, layer } = useLeafletMap()
  const fitted = useRef('')
  const { summary } = props

  const points = () => {
    const all: [number, number][] = []
    for (const h of summary.hops) for (const l of [h.chosen, ...h.options]) if (l) {
      if (l.from_latitude || l.from_longitude) all.push([l.from_latitude, l.from_longitude])
      if (l.to_latitude || l.to_longitude) all.push([l.to_latitude, l.to_longitude])
    }
    return all
  }
  const fit = () => { const all = points(); if (map.current && all.length) map.current.fitBounds(L.latLngBounds(all), { padding: [48, 48], maxZoom: 9, animate: false }) }

  useEffect(() => {
    if (!map.current || !layer.current) return
    layer.current.clearLayers()
    const target = layer.current
    const line = (l: LegView, options: L.PolylineOptions, side: 1 | -1, badge: boolean) => {
      if (!(l.from_latitude || l.from_longitude) || !(l.to_latitude || l.to_longitude)) return
      const text = [`${l.from_name} → ${l.to_name}`, l.mode_label + (l.line ? ` ${l.line}` : ''), duration(l.duration_minutes),
        l.price ? `${money(l.price, l.currency_code)} p. P.` : ''].filter(Boolean).join(' · ')
      const dash = l.path ? undefined : DASH[l.mode]
      // Rails and roads follow the real way once it is known; everything else (and anything not looked up yet) is an arc.
      const real = l.path && l.path.length > 1
      const path = real ? l.path! : curve([l.from_latitude, l.from_longitude], [l.to_latitude, l.to_longitude], (l.mode === 'flight' ? 0.28 : 0.14) * side)
      L.polyline(path, { ...options, ...(dash && !options.dashArray ? { dashArray: dash } : {}), lineCap: 'round' }).addTo(target).bindTooltip(text, { sticky: true })
      if (!badge) return
      const at = (f: number) => along(path, f)
      const before = at(0.52), after = at(0.62)
      // The arrow shows the direction of travel; the badge names the way and how long it takes.
      const angle = (Math.atan2(after[0] - before[0], after[1] - before[1]) * 180) / Math.PI
      L.marker(at(0.6), { interactive: false, icon: L.divIcon({ className: '', iconSize: [14, 14], iconAnchor: [7, 7],
        html: `<div class="arrow-head" style="color:${options.color};transform:rotate(${90 - angle}deg)">▶</div>` }) }).addTo(target)
      const label = [modeGlyph(l.mode), duration(l.duration_minutes).replace(' Std.', ' h').replace(' Min.', ' min'), l.price ? money(l.price, l.currency_code) : ''].filter(Boolean).join(' · ')
      L.marker(at(0.5), { icon: L.divIcon({ className: '', iconSize: [0, 0], html: `<div class="leg-badge" style="border-color:${options.color}">${label}</div>` }) })
        .addTo(target).bindTooltip(text, { direction: 'top', offset: [0, -12] })
    }
    summary.hops.forEach((h, index) => {
      const selected = h.hop === props.selectedHop
      const side = index % 2 ? -1 : 1
      if (h.chosen) line(h.chosen, { color: modeColor(h.chosen.mode), weight: selected ? 7 : 5, opacity: 0.9 }, side, true)
      else if (h.options[0]) line(h.options[0], { color: '#9e9e9e', weight: 3, dashArray: '4 8', opacity: 0.8 }, side, false)     // nothing chosen yet
      if (selected) h.options.forEach((o, i) => { if (h.chosen) line(o, { color: modeColor(o.mode), weight: 3, dashArray: '8 8', opacity: 0.6 }, i % 2 ? 1 : -1, false) })
    })
    const picked = summary.hops.find((h) => h.hop === props.selectedHop)
    for (const n of picked?.nearby ?? []) {
      const full = props.places?.find((p) => p.id === n.id)
      if (full) L.circleMarker([full.latitude, full.longitude], { radius: 6, color: '#fff', weight: 2, fillColor: '#e08a00', fillOpacity: 0.95 }).addTo(target).bindTooltip(`${n.name} · ${n.distance_km} km von der Strecke`)
    }
    const stations = summary.places.filter((p) => p.has_position)
    stations.forEach((p, index) => {
      const into = summary.hops[index - 1]?.chosen, out = summary.hops[index]?.chosen
      const change = into && out && into.mode !== out.mode ? `Umstieg: ${into.mode_label} → ${out.mode_label}` : ''
      const role = index === 0 ? 'Start' : index === stations.length - 1 ? 'Ziel' : change
      L.marker([p.latitude, p.longitude], {
        icon: L.divIcon({ className: '', html: `<div class="pin${change ? ' change' : ''}">${index + 1}</div>`, iconSize: [28, 28], iconAnchor: [14, 14] }),
      }).addTo(target).bindTooltip(role ? `${p.name} · ${role}` : p.name, { direction: 'top', offset: [0, -12] })
    })
    const key = JSON.stringify(points())
    if (fitted.current !== key) { fit(); fitted.current = key }
  }, [summary, props.selectedHop])

  const used = [...new Set(summary.hops.map((h) => h.chosen?.mode).filter(Boolean) as string[])]
  return (
    <MapFrame element={element} label="Karte der Route" expanded={props.expanded} onExpand={props.onExpand} onFit={fit} fitLabel="Ganze Route zeigen">
      {props.expanded && used.length > 0 && (
        <div class="map-panel"><div class="legends">{used.map((m) => <span class="legend"><i style={{ background: modeColor(m) }} />{modeLabel(m)}</span>)}</div></div>
      )}
    </MapFrame>
  )
}

// MARK: JR Pass or single tickets

function PassCard({ pass }: { pass: PassComparison }) {
  if (pass.covered === 0 && pass.notes.length === 0) return null
  const money_ = (v: number) => money(v, pass.currency)
  const best = pass.options.find((o) => o.days === pass.best_days)
  return (
    <section class="card" aria-label="JR Pass oder Einzeltickets">
      <h3>JR Pass oder Einzeltickets?</h3>
      {pass.covered > 0 && (
        <>
          <div class="meta">{pass.covered} gewählte {pass.covered === 1 ? 'Fahrt ist' : 'Fahrten sind'} vom Pass gedeckt. Einzeltickets dafür: {money_(pass.singles_per_person)} pro Person, {money_(pass.singles_for_group)} für {pass.travelers}.</div>
          {pass.span_days && <div class="meta">Zwischen erster und letzter gedeckter Fahrt liegen {pass.span_days} {pass.span_days === 1 ? 'Tag' : 'Tage'}.</div>}
          <div class="pass-options">
            {pass.options.map((o) => (
              <div class={`pass-option${o.days === pass.best_days ? ' best' : ''}${o.fits === false ? ' off' : ''}`}>
                <b>{o.days} Tage</b>
                <span>{money_(o.price_per_person)} pro Person</span>
                <span>{money_(o.price_for_group)} für {pass.travelers}</span>
                <span class={o.saves_for_group > 0 ? 'good' : 'bad'}>{o.saves_for_group > 0 ? `spart ${money_(o.saves_for_group)}` : `kostet ${money_(-o.saves_for_group)} mehr`}</span>
                {o.fits === false && <span class="meta">reicht nicht</span>}
              </div>
            ))}
          </div>
          {pass.verdict && best && (
            <p class="verdict"><b>{pass.verdict === 'pass' ? `Der ${best.days}-Tage-Pass lohnt sich.` : 'Einzeltickets sind günstiger.'}</b>
              {pass.verdict === 'pass' ? ` Ersparnis für ${pass.travelers} Personen: ${money_(best.saves_for_group)}.` : ` Der Pass würde ${money_(-best.saves_for_group)} mehr kosten.`}</p>
          )}
        </>
      )}
      {pass.notes.map((n) => <div class="meta">{n}</div>)}
      <div class="meta">{pass.price_list}.</div>
    </section>
  )
}

// MARK: One way of getting somewhere

function Price(props: { leg: LegView; currency: string; travelers: number }) {
  const { leg, currency, travelers } = props
  if (!leg.price) return <div class="meta">Preis noch offen</div>
  const other = leg.currency_code !== currency
  return (
    <div class="meta">
      {money(leg.price, leg.currency_code)} pro Person
      {other && leg.price_in_trip_currency != null && ` ≈ ${money(leg.price_in_trip_currency, currency)}`}
      {travelers > 1 && leg.group_price != null && ` · für ${travelers} Personen ${money(leg.group_price, currency)}`}
    </div>
  )
}

function LegBlock(props: { leg: LegView; currency: string; travelers: number; canEdit: boolean; onChoose: () => void; onEdit: () => void }) {
  const { leg } = props
  const link = safeUrl(leg.source_url)
  return (
    <div class={`leg${leg.status === 'option' ? ' option' : ''}`}>
      <div class="body">
        <div class="title">
          <span class="mode" style={{ background: modeColor(leg.mode) }}>{leg.mode_label}</span> {leg.line || 'ohne Linie'}
          <span class={`badge${leg.status !== 'option' ? ' claude' : ''}`}>{STATUS_LABEL[leg.status]}</span>{leg.pass_ok ? <span class="badge">JR Pass</span> : null}
        </div>
        <div class="meta">{[duration(leg.duration_minutes), leg.departure && `ab ${dateTimeLabel(leg.departure)}`, leg.arrival && `an ${dateTimeLabel(leg.arrival)}`].filter(Boolean).join(' · ') || 'Dauer noch offen'}</div>
        <Price leg={leg} currency={props.currency} travelers={props.travelers} />
        {leg.notes && <div class="meta">{leg.notes}</div>}
        {leg.reference && <div class="meta">Referenz: {leg.reference}</div>}
        {(leg.source || link) && <div class="meta">Quelle: {link ? <a href={link} target="_blank" rel="noopener noreferrer">{leg.source || link}</a> : leg.source}</div>}
      </div>
      {props.canEdit && (
        <div class="place-actions">
          {leg.status === 'option' && <button type="button" class="btn secondary" onClick={props.onChoose}>Wählen</button>}
          <button type="button" class="btn quiet" onClick={props.onEdit}>Bearbeiten</button>
        </div>
      )}
    </div>
  )
}

// MARK: The route

type Editing = { leg?: Leg; from?: { name: string; latitude: number; longitude: number }; to?: { name: string; latitude: number; longitude: number }; hop?: number }

export function Route({ data, canEdit, reload }: ViewProps) {
  const { trip } = data
  const notify = useNotify()
  const run = useOperation(reload)
  const [summary, setSummary] = useState<RouteSummary | null>(null)
  const [selected, setSelected] = useState<number | null>(null)
  const [expanded, setExpanded] = useState(false)
  const [editing, setEditing] = useState<Editing | null>(null)

  const asked = useRef(new Set<string>())
  const [loadingPaths, setLoadingPaths] = useState(0)

  useEffect(() => { api.route(trip.id).then(setSummary).catch((e) => notify(messageOf(e), true)) }, [trip.id, data.revision])

  // Looking up the real rails and roads takes a while the first time, so it happens one leg after the other in the background, and the map redraws as each arrives.
  useEffect(() => {
    if (!summary) return
    const wanted = summary.hops.flatMap((h) => [h.chosen, ...(h.hop === selected ? h.options : [])]).filter((l): l is LegView =>
      !!l && !l.path && !asked.current.has(l.id) && ['shinkansen', 'train', 'bus', 'car', 'taxi'].includes(l.mode) && !!(l.from_latitude || l.from_longitude) && !!(l.to_latitude || l.to_longitude))
    if (!wanted.length) return
    let cancelled = false
    ;(async () => {
      for (const leg of wanted) {
        if (cancelled) return
        asked.current.add(leg.id)
        setLoadingPaths((n) => n + 1)
        try {
          const { path } = await api.legPath(leg.id)
          if (path && !cancelled) setSummary((s) => s && ({ ...s, hops: s.hops.map((h) => ({ ...h, chosen: h.chosen && h.chosen.id === leg.id ? { ...h.chosen, path } : h.chosen,
            options: h.options.map((o) => (o.id === leg.id ? { ...o, path } : o)) })) }))
        } catch { /* no real way known: the map keeps the arc */ }
        setLoadingPaths((n) => n - 1)
      }
    })()
    return () => { cancelled = true }
  }, [summary?.hops.map((h) => `${h.chosen?.id}${h.chosen?.path ? '+' : ''}`).join(), selected])

  if (!summary) return <Skeleton lines={4} />
  const legOf = (id: string) => data.legs.find((l) => l.id === id)
  const last = summary.hops[summary.hops.length - 1]
  const lastLeg = last && (last.chosen ?? last.options[0])
  const names = summary.places.map((p) => p.name)

  const startNewHop = () => setEditing({ from: lastLeg ? { name: lastLeg.to_name, latitude: lastLeg.to_latitude, longitude: lastLeg.to_longitude } : undefined })

  return (
    <>
      {summary.hops.length === 0 ? (
        <>
          <p class="empty">Noch keine Route. Hier planst du, wo ihr startet und wie ihr von Ort zu Ort kommt, zum Beispiel Tokyo → Osaka mit dem Shinkansen. Bitte Claude, Vorschläge mit Fahrzeit und Preis einzutragen, oder lege selbst einen Abschnitt an.</p>
          {canEdit && <button class="btn" onClick={startNewHop}>Ersten Abschnitt anlegen</button>}
        </>
      ) : (
        <>
          <RouteMap places={data.places} summary={summary} selectedHop={selected} expanded={expanded} onExpand={setExpanded} />
          {loadingPaths > 0 && <p class="note" role="status">Echter Gleis- und Strassenverlauf wird geladen …</p>}
          <div class="route-strip" aria-label="Route">{names.map((n, i) => <span>{i > 0 && <span class="arrow"> → </span>}<b>{n}</b></span>)}</div>
          <div class="card">
            <div class="row"><div class="body">
              <div class="title">{summary.hops.length} {summary.hops.length === 1 ? 'Abschnitt' : 'Abschnitte'}{summary.decided < summary.hops.length ? `, ${summary.decided} gewählt` : ''}</div>
              <div class="meta">Unterwegs insgesamt: {duration(summary.total_minutes) || 'noch offen'}</div>
              <div class="meta">Fahrtkosten: {money(summary.price_per_person, summary.currency)} pro Person{summary.travelers > 1 ? ` · für ${summary.travelers} Personen ${money(summary.price_for_group, summary.currency)}` : ''}</div>
              {summary.warnings.map((w) => <div class="meta warn">{w}</div>)}
            </div></div>
          </div>
          <PassCard pass={summary.pass} />
          {summary.hops.map((hop, index) => {
            const any = hop.chosen ?? hop.options[0]
            const open = (leg?: Leg) => setEditing({ leg, hop: hop.hop, from: { name: any.from_name, latitude: any.from_latitude, longitude: any.from_longitude },
              to: { name: any.to_name, latitude: any.to_latitude, longitude: any.to_longitude } })
            return (
              <section class={`card hop${selected === hop.hop ? ' selected' : ''}`} onClick={() => setSelected(selected === hop.hop ? null : hop.hop)} aria-label={`Abschnitt ${hop.hop}`}>
                <div class="hop-head">
                  <h3>{index + 1} · {hop.from_name} → {hop.to_name}</h3>
                  {canEdit && (
                    <div class="hop-move" onClick={(e) => e.stopPropagation()}>
                      <button type="button" class="btn quiet" aria-label={`Abschnitt ${hop.hop} nach oben`} disabled={index === 0} onClick={() => run('Abschnitt verschoben', () => api.moveHop(trip.id, hop.hop, -1))}>↑</button>
                      <button type="button" class="btn quiet" aria-label={`Abschnitt ${hop.hop} nach unten`} disabled={index === summary.hops.length - 1} onClick={() => run('Abschnitt verschoben', () => api.moveHop(trip.id, hop.hop, 1))}>↓</button>
                    </div>
                  )}
                </div>
                <div onClick={(e) => e.stopPropagation()}>
                  {hop.chosen
                    ? <LegBlock leg={hop.chosen} currency={summary.currency} travelers={summary.travelers} canEdit={canEdit} onChoose={() => {}} onEdit={() => open(legOf(hop.chosen!.id))} />
                    : <p class="note">Noch nichts gewählt. Wähle unten eine Option.</p>}
                  {hop.options.map((o) => (
                    <LegBlock leg={o} currency={summary.currency} travelers={summary.travelers} canEdit={canEdit}
                      onChoose={() => run(`Gewählt: ${o.mode_label} ${o.line}`.trim(), () => api.chooseLeg(o.id))} onEdit={() => open(legOf(o.id))} />
                  ))}
                  {hop.nearby.length > 0 && (
                    <details class="nearby" open={selected === hop.hop}>
                      <summary>Auf dem Weg: {hop.nearby.length} {hop.nearby.length === 1 ? 'Idee' : 'Ideen'} bis 25 km neben der Strecke</summary>
                      {hop.nearby.map((n) => (
                        <div class="nearby-row">
                          <span><b>{n.name}</b>{n.region && ` · ${n.region}`}</span>
                          <span class="meta">{[categoryLabel(n.category || 'other'), n.prio, `${n.distance_km} km von der Strecke`, n.decision === 'Ja' ? 'schon beschlossen' : ''].filter(Boolean).join(' · ')}</span>
                        </div>
                      ))}
                      <p class="note">Ein Zwischenstopp dort kostet etwa den doppelten Abstand als Umweg. Sag Claude, welche ihr einbauen wollt.</p>
                    </details>
                  )}
                  {canEdit && <div class="actions"><button type="button" class="btn quiet" onClick={() => open(undefined)}>Weitere Option für diesen Abschnitt</button></div>}
                </div>
              </section>
            )
          })}
          {canEdit && <div class="actions"><button class="btn" onClick={startNewHop}>Nächsten Abschnitt hinzufügen</button></div>}
        </>
      )}
      {editing && <LegDialog data={data} editing={editing} reload={reload} onClose={() => setEditing(null)} />}
    </>
  )
}

// MARK: Adding and editing a leg

type Place = { name: string; latitude: number; longitude: number }

function PlaceField(props: { label: string; value: Place; near?: [number, number]; onChange: (p: Place) => void }) {
  const { value } = props
  const pick = (f: FoundPlace) => props.onChange({ name: f.name, latitude: f.latitude, longitude: f.longitude })
  return (
    <fieldset class="facet">
      <legend>{props.label}</legend>
      <Field label="Name"><input value={value.name} required maxLength={200} onInput={(e) => props.onChange({ ...value, name: (e.target as HTMLInputElement).value })} /></Field>
      <PlaceSearch near={props.near} label="Suchen (für die Position auf der Karte)" onPick={pick} />
      <p class="note">{value.latitude || value.longitude ? `Position gesetzt (${value.latitude.toFixed(3)}, ${value.longitude.toFixed(3)}).` : 'Ohne Position erscheint die Linie nicht auf der Karte.'}</p>
    </fieldset>
  )
}

function LegDialog(props: { data: TripData; editing: Editing; reload: () => Promise<void>; onClose: () => void }) {
  const notify = useNotify()
  const { trip } = props.data
  const { leg, hop, from, to } = props.editing
  const blank: Place = { name: '', latitude: 0, longitude: 0 }
  const [start, setStart] = useState<Place>(leg ? { name: leg.from_name, latitude: leg.from_latitude, longitude: leg.from_longitude } : from ?? blank)
  const [end, setEnd] = useState<Place>(leg ? { name: leg.to_name, latitude: leg.to_latitude, longitude: leg.to_longitude } : to ?? blank)
  const [mode, setMode] = useState(leg?.mode ?? 'shinkansen')
  const [line, setLine] = useState(leg?.line ?? '')
  const [hours, setHours] = useState(leg ? String(Math.floor(leg.duration_minutes / 60)) : '')
  const [minutes, setMinutes] = useState(leg ? String(leg.duration_minutes % 60) : '')
  const [price, setPrice] = useState(leg?.price ? String(leg.price) : '')
  const [currency, setCurrency] = useState(leg?.currency_code ?? (trip.country_code === 'JP' ? 'JPY' : trip.currency_code))
  const [departure, setDeparture] = useState(leg?.departure ?? '')
  const [arrival, setArrival] = useState(leg?.arrival ?? '')
  const [notes, setNotes] = useState(leg?.notes ?? '')
  const [source, setSource] = useState(leg?.source ?? '')
  const [sourceUrl, setSourceUrl] = useState(leg?.source_url ?? '')
  const [reference, setReference] = useState(leg?.reference ?? '')
  const [passOk, setPassOk] = useState(!!leg?.pass_ok)
  const [busy, setBusy] = useState(false)
  const near = biasOf(props.data)
  const text = (set: (v: string) => void) => (e: Event) => set((e.target as HTMLInputElement | HTMLTextAreaElement).value)

  const save = async (event: Event) => {
    event.preventDefault()
    setBusy(true)
    try {
      const body: Record<string, unknown> = {
        from_name: start.name, to_name: end.name, mode, line, duration_minutes: Math.max(0, (Number(hours) || 0) * 60 + (Number(minutes) || 0)),
        price: Math.max(0, Number(price.replace(',', '.')) || 0), currency_code: currency.toUpperCase(), departure: departure || null, arrival: arrival || null,
        notes, source, source_url: sourceUrl, reference, pass_ok: passOk,
        ...(start.latitude || start.longitude ? { from_latitude: start.latitude, from_longitude: start.longitude } : {}),
        ...(end.latitude || end.longitude ? { to_latitude: end.latitude, to_longitude: end.longitude } : {}),
      }
      if (leg) await api.patch('leg', leg.id, body)
      else await api.createItem(trip.id, 'leg', { ...body, ...(hop ? { hop } : {}) })
      await props.reload(); props.onClose()
    } catch (error) { notify(messageOf(error), true); setBusy(false) }
  }
  const remove = async () => {
    setBusy(true)
    try { await api.deleteItem('leg', leg!.id); await props.reload(); props.onClose() } catch (error) { notify(messageOf(error), true); setBusy(false) }
  }

  return (
    <Modal title={leg ? 'Etappe bearbeiten' : hop ? 'Weitere Option' : 'Neuer Abschnitt'} onClose={props.onClose}>
      <form onSubmit={save}>
        <PlaceField label="Von" value={start} near={near} onChange={setStart} />
        <PlaceField label="Nach" value={end} near={near} onChange={setEnd} />
        <div class="two">
          <Field label="Verkehrsmittel"><select value={mode} onChange={(e) => setMode((e.target as HTMLSelectElement).value)}>{MODES.map((m) => <option value={m.id}>{m.label}</option>)}</select></Field>
          <Field label="Linie / Zug"><input value={line} onInput={text(setLine)} placeholder="z. B. Nozomi" maxLength={200} /></Field>
        </div>
        <div class="two">
          <Field label="Dauer (Std.)"><input inputMode="numeric" value={hours} onInput={text(setHours)} /></Field>
          <Field label="Dauer (Min.)"><input inputMode="numeric" value={minutes} onInput={text(setMinutes)} /></Field>
        </div>
        <div class="two">
          <Field label="Preis pro Person"><input inputMode="decimal" value={price} onInput={text(setPrice)} /></Field>
          <Field label="Währung"><input value={currency} onInput={text(setCurrency)} maxLength={3} required /></Field>
        </div>
        <div class="two">
          <Field label="Abfahrt (optional)"><input type="datetime-local" value={departure} onInput={text(setDeparture)} /></Field>
          <Field label="Ankunft (optional)"><input type="datetime-local" value={arrival} onInput={text(setArrival)} /></Field>
        </div>
        <Field label="Notizen" hint="Zum Beispiel Reservierung, JR Pass, Umstiege, Gepäck."><textarea rows={3} value={notes} onInput={text(setNotes)} /></Field>
        <div class="two">
          <Field label="Quelle und Stand"><input value={source} onInput={text(setSource)} placeholder="z. B. JR Central, Okt. 2026" maxLength={300} /></Field>
          <Field label="Link zur Quelle"><input type="url" value={sourceUrl} onInput={text(setSourceUrl)} placeholder="https://…" /></Field>
        </div>
        <label class="check"><input type="checkbox" checked={passOk} onChange={(e) => setPassOk((e.target as HTMLInputElement).checked)} />Vom JR Pass gedeckt (Nozomi und Mizuho sind es nicht)</label>
        <Field label="Buchungsreferenz"><input value={reference} onInput={text(setReference)} maxLength={100} /></Field>
        <div class="actions">
          <button class="btn" type="submit" disabled={busy}>{leg ? 'Speichern' : 'Hinzufügen'}</button>
          <button class="btn quiet" type="button" onClick={props.onClose}>Abbrechen</button>
          {leg && <ConfirmButton label="Löschen" onConfirm={remove} disabled={busy} />}
        </div>
      </form>
    </Modal>
  )
}
