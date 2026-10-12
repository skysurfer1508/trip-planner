import { useEffect, useState } from 'preact/hooks'
import { api } from './api'
import { CATEGORIES, categoryColor, categoryLabel } from './categories'
import { biasOf, PlaceDialog } from './edit'
import {
  DURATIONS, NO_REGION, PRIOS, SORTS, VERDICTS, activeCount, clearFilter, facetCounts, filterPlaces, groupByRegion, sortPlaces,
  type Facet, type IdeaFilter, type SortKey,
} from './filters'
import { Legend, IdeasMap, PRIO_COLOR, colorOf, type ColorBy } from './map'
import type { Place, Verdict, Vote } from './types'
import { messageOf, useNotify } from './ui'
import type { ViewProps } from './views'

const remembered = (key: string): string | null => { try { return localStorage.getItem(key) } catch { return null } }
const remember = (key: string, value: string) => { try { localStorage.setItem(key, value) } catch { /* private mode */ } }

const toggled = <T,>(set: Set<T>, value: T): Set<T> => { const next = new Set(set); if (next.has(value)) next.delete(value); else next.add(value); return next }

/** One group of filter chips. Each chip shows how many places it would give, given everything else that is chosen. */
function FacetChips(props: { title: string; facet: Facet; places: Place[]; filter: IdeaFilter; set: (f: IdeaFilter) => void; order?: readonly string[];
  label?: (value: string) => string; dot?: (value: string) => string }) {
  const selected = props.filter[props.facet] as Set<string>
  let entries = facetCounts(props.places, props.filter, props.facet)
  if (props.order) entries = [...entries].sort((a, b) => props.order!.indexOf(a[0]) - props.order!.indexOf(b[0]))
  if (entries.length === 0 || (entries.length === 1 && selected.size === 0 && props.facet !== 'verdicts')) return null
  return (
    <fieldset class="facet">
      <legend>{props.title}</legend>
      <div class="chips">
        {entries.map(([value, count]) => (
          <button type="button" class={`chip${count === 0 && !selected.has(value) ? ' none' : ''}`} aria-pressed={selected.has(value)}
            onClick={() => props.set({ ...props.filter, [props.facet]: toggled(selected, value) })}>
            {props.dot && <i class="chip-dot" style={{ background: props.dot(value) }} />}
            {props.label ? props.label(value) : value}<span class="count">{count}</span>
          </button>
        ))}
      </div>
    </fieldset>
  )
}

function Filters(props: { places: Place[]; filter: IdeaFilter; set: (f: IdeaFilter) => void }) {
  const { places, filter, set } = props
  const common = { places, filter, set }
  return (
    <div class="filters">
      <FacetChips {...common} title="Region" facet="regions" />
      <FacetChips {...common} title="Kategorie" facet="categories" order={CATEGORIES.map((c) => c.id)} label={categoryLabel} dot={categoryColor} />
      <FacetChips {...common} title="Priorität" facet="prios" order={PRIOS} dot={(v) => PRIO_COLOR[v as keyof typeof PRIO_COLOR]} />
      <FacetChips {...common} title="Entscheid" facet="verdicts" order={VERDICTS} />
      <FacetChips {...common} title="Dauer" facet="durations" order={DURATIONS} />
      <FacetChips {...common} title="Für wen" facet="forWhom" />
      <FacetChips {...common} title="Wunsch von" facet="wishedBy" />
      <label class="check"><input type="checkbox" checked={filter.positionOnly} onChange={(e) => set({ ...filter, positionOnly: (e.target as HTMLInputElement).checked })} /> Nur Orte mit Position (auf der Karte)</label>
    </div>
  )
}

/** Everyone's thumbs: your own vote is highlighted, the names of the others show on hover or long press. */
function VoteBar(props: { place: Place; votes: Vote[]; me: string; onVote: (value: -1 | 0 | 1) => void }) {
  const mine = props.votes.find((v) => v.voter === props.me)?.value ?? 0
  const people = (value: number) => {
    const seen = new Map<string, string>()
    for (const v of props.votes) if (v.value === value && !seen.has(v.name.toLowerCase())) seen.set(v.name.toLowerCase(), v.name)
    return [...seen.values()]
  }
  const yes = people(1), no = people(-1)
  const button = (value: 1 | -1, label: string, names: string[]) => (
    <button type="button" class="vote" aria-pressed={mine === value} title={names.join(', ') || 'noch niemand'}
      aria-label={`${value === 1 ? 'Gefällt' : 'Gefällt nicht'} (${names.length}${names.length ? `: ${names.join(', ')}` : ''})`} onClick={() => props.onVote(mine === value ? 0 : value)}>
      {label} <b>{names.length}</b>
    </button>
  )
  return <div class="votes" role="group" aria-label={`Abstimmung für ${props.place.name}`}>{button(1, '👍', yes)}{button(-1, '👎', no)}</div>
}

/** The picture of a place, found on the server (Wikipedia). It stays out of the way when there is none, and credits its source once loaded. */
function PlacePhoto({ place }: { place: Place }) {
  const [state, setState] = useState<'loading' | 'ok' | 'none'>('loading')
  const [source, setSource] = useState<{ title: string; page: string } | null>(null)
  const url = `/api/places/${encodeURIComponent(place.id)}/photo`
  // A rename or a new position means a new picture lookup, so start over.
  useEffect(() => { setState('loading'); setSource(null) }, [place.name, place.region, place.latitude, place.longitude])
  if (state === 'none') return null
  return (
    <figure class={`place-photo${state === 'ok' ? ' ready' : ''}`}>
      <img src={`${url}?n=${encodeURIComponent(place.name)}`} alt="" loading="lazy" decoding="async"
        onLoad={() => { setState('ok'); fetch(`${url}/source`).then((r) => (r.ok ? r.json() : null)).then(setSource).catch(() => {}) }}
        onError={() => setState('none')} />
      {source && <figcaption><a href={source.page} target="_blank" rel="noopener noreferrer" onClick={(e) => e.stopPropagation()}>Foto: {source.title} (Wikipedia)</a></figcaption>}
    </figure>
  )
}

function Rating(props: { place: Place; onChange: (v: Verdict) => void }) {
  return (
    <div class="seg" role="group" aria-label={`Entscheid für ${props.place.name}`}>
      {VERDICTS.map((v) => <button type="button" aria-pressed={props.place.decision === v} onClick={() => props.onChange(v)}>{v}</button>)}
    </div>
  )
}

export function Ideas(props: ViewProps & { filter: IdeaFilter; setFilter: (f: IdeaFilter) => void }) {
  const { data, canEdit, filter } = props
  const { places } = data
  const notify = useNotify()
  const [focused, setFocused] = useState<string | null>(null)
  const [editing, setEditing] = useState<Place | 'new' | null>(null)
  const [panel, setPanel] = useState(remembered('ideas-panel') === '1')
  const [expanded, setExpanded] = useState(false)
  const [colorBy, setColorBy] = useState<ColorBy>(remembered('ideas-color') === 'category' ? 'category' : 'prio')
  const [folded, setFolded] = useState<Set<string>>(new Set())

  useEffect(() => remember('ideas-panel', panel ? '1' : '0'), [panel])
  useEffect(() => remember('ideas-color', colorBy), [colorBy])

  const setDecision = async (place: Place, decision: Verdict) => {
    try { await api.patch('place', place.id, { decision }); await props.reload() } catch (error) { notify(messageOf(error), true) }
  }
  const dialog = editing && <PlaceDialog tripId={data.trip.id} place={editing === 'new' ? undefined : editing} regions={[...new Set(places.map((p) => p.region).filter(Boolean))]} near={biasOf(data)} onClose={() => setEditing(null)} onSaved={props.reload} />

  if (places.length === 0) {
    return (
      <>
        <p class="empty">Noch keine Ideen. Füge einen Ort hinzu oder bitte Claude, Orte einzutragen.</p>
        {canEdit && <button class="btn" onClick={() => setEditing('new')}>Ort hinzufügen</button>}
        {dialog}
      </>
    )
  }

  const votesOf = (id: string) => data.votes.filter((v) => v.place_id === id)
  const score: Record<string, number> = {}
  for (const p of places) { const seen = new Map<string, number>(); for (const v of votesOf(p.id)) if (!seen.has(v.name.toLowerCase())) seen.set(v.name.toLowerCase(), v.value); score[p.id] = [...seen.values()].reduce((a, b) => a + b, 0) }
  const vote = async (place: Place, value: -1 | 0 | 1) => {
    const mine = data.votes.find((v) => v.place_id === place.id && v.voter === data.me)
    props.mutate((d) => ({ ...d, votes: [...d.votes.filter((v) => !(v.place_id === place.id && v.voter === d.me)),
      ...(value === 0 ? [] : [{ place_id: place.id, voter: d.me, name: mine?.name ?? d.members.find((m) => m.sub === d.me)?.name ?? '', value }])] }))
    try { await api.vote(place.id, value); await props.reload() } catch (error) { notify(messageOf(error), true); await props.reload() }
  }
  const shown = sortPlaces(filterPlaces(places, filter), filter.sort, score)
  const groups = filter.group ? groupByRegion(shown) : [{ region: '', places: shown }]
  const active = activeCount(filter)
  const selected = places.find((p) => p.id === focused) ?? null
  // The map follows the filter, but not every little edit: it frames the places again only when the filter itself changes.
  const fitKey = [filter.q, filter.positionOnly, ...(['regions', 'categories', 'prios', 'verdicts', 'durations', 'forWhom', 'wishedBy'] as const).map((f) => [...(filter[f] as Set<string>)].join('|'))].join('~')

  const pick = (id: string) => {
    setFocused(id)
    if (!expanded) document.querySelector<HTMLElement>(`[data-place="${CSS.escape(id)}"]`)?.scrollIntoView({ behavior: 'smooth', block: 'center' })
  }

  const row = (p: Place) => (
    <div class={`row place${p.decision === 'Nein' ? ' dim' : ''}${p.id === focused ? ' focus' : ''}`} data-place={p.id} tabIndex={0} role="button" onClick={() => setFocused(p.id)}
      onKeyDown={(e) => { if (e.target === e.currentTarget && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); setFocused(p.id) } }}>
      <PlacePhoto place={p} />
      <div class="body">
        <div class="title">{p.name}</div>
        <div class="meta"><i class="chip-dot" style={{ background: categoryColor(p.category || 'other') }} />{[categoryLabel(p.category || 'other'), !filter.group && p.region, p.duration, p.heat].filter(Boolean).join(' · ')}</div>
        {p.description && <div class="meta">{p.description}</div>}
        {p.notes && <div class="meta">{p.notes}</div>}
        {(p.for_whom || p.wished_by) && <div class="meta">{[p.for_whom && `Für wen: ${p.for_whom}`, p.wished_by && `Wunsch von: ${p.wished_by}`].filter(Boolean).join(' · ')}</div>}
      </div>
      <div class="end"><span class="dot" style={{ background: PRIO_COLOR[p.prio] }} /> {p.prio}<br /><span class="meta">{p.decision}</span></div>
      <div class="place-actions" onClick={(e) => e.stopPropagation()}>
        <VoteBar place={p} votes={votesOf(p.id)} me={data.me} onVote={(v) => vote(p, v)} />
        {canEdit && <Rating place={p} onChange={(v) => setDecision(p, v)} />}
        {canEdit && <button type="button" class="btn quiet" onClick={() => setEditing(p)}>Bearbeiten</button>}
      </div>
    </div>
  )

  return (
    <>
      {canEdit && <div class="actions"><button class="btn" onClick={() => setEditing('new')}>Ort hinzufügen</button></div>}
      <IdeasMap places={shown} colorBy={colorBy} focused={focused} fitKey={fitKey} expanded={expanded} onExpand={setExpanded} onPick={pick}>
        {expanded && (
          <div class="map-panel">
            <Legend places={shown} by={colorBy} />
            <div class="seg" role="group" aria-label="Karte einfärben nach">
              <button type="button" aria-pressed={colorBy === 'prio'} onClick={() => setColorBy('prio')}>Priorität</button>
              <button type="button" aria-pressed={colorBy === 'category'} onClick={() => setColorBy('category')}>Kategorie</button>
            </div>
            <span class="note">{shown.filter((p) => p.has_coordinate).length} Orte auf der Karte</span>
            {selected && (
              <div class="map-card">
                <div class="title">{selected.name}</div>
                <div class="meta">{[categoryLabel(selected.category || 'other'), selected.region, selected.duration, selected.prio].filter(Boolean).join(' · ')}</div>
                {selected.description && <div class="meta">{selected.description}</div>}
                <div class="place-actions">
                  {canEdit && <Rating place={selected} onChange={(v) => setDecision(selected, v)} />}
                  {canEdit && <button type="button" class="btn quiet" onClick={() => setEditing(selected)}>Bearbeiten</button>}
                  <button type="button" class="btn quiet" onClick={() => setFocused(null)}>Schliessen</button>
                </div>
              </div>
            )}
          </div>
        )}
      </IdeasMap>
      {!expanded && (
        <div class="map-legend-row">
          <Legend places={shown} by={colorBy} />
          <div class="seg" role="group" aria-label="Karte einfärben nach">
            <button type="button" aria-pressed={colorBy === 'prio'} onClick={() => setColorBy('prio')}>Priorität</button>
            <button type="button" aria-pressed={colorBy === 'category'} onClick={() => setColorBy('category')}>Kategorie</button>
          </div>
        </div>
      )}

      <div class="toolbar">
        <input type="search" class="grow" placeholder="Suchen (Name, Region, Kategorie, Notizen …)" aria-label="Orte suchen" value={filter.q}
          onInput={(e) => props.setFilter({ ...filter, q: (e.target as HTMLInputElement).value })} />
        <button type="button" class="btn secondary" aria-expanded={panel} onClick={() => setPanel(!panel)}>Filter{active > 0 ? ` (${active})` : ''}</button>
      </div>
      {panel && <Filters places={places} filter={filter} set={props.setFilter} />}
      <div class="toolbar">
        <label class="inline">Sortieren
          <select value={filter.sort} onChange={(e) => props.setFilter({ ...filter, sort: (e.target as HTMLSelectElement).value as SortKey })}>
            {SORTS.map(([key, label]) => <option value={key}>{label}</option>)}
          </select>
        </label>
        <label class="check"><input type="checkbox" checked={filter.group} onChange={(e) => props.setFilter({ ...filter, group: (e.target as HTMLInputElement).checked })} /> Nach Region gruppieren</label>
      </div>
      <p class="note">
        {shown.length} von {places.length} Orten{active > 0 && <> · <button type="button" class="link" onClick={() => props.setFilter(clearFilter(filter))}>Alle Filter entfernen</button></>}
      </p>

      {shown.length === 0 && <p class="empty">Kein Ort passt zu den Filtern.</p>}
      {groups.map((group) => {
        const closed = folded.has(group.region)
        return (
          <>
            {filter.group && (
              <button type="button" class="group-head" aria-expanded={!closed} onClick={() => setFolded(toggled(folded, group.region))}>
                <span>{closed ? '▸' : '▾'} {group.region || NO_REGION}</span><span class="meta">{group.places.length} {group.places.length === 1 ? 'Ort' : 'Orte'}</span>
              </button>
            )}
            {!closed && <div class="card">{group.places.map(row)}</div>}
          </>
        )
      })}
      {dialog}
    </>
  )
}
export { colorOf }
