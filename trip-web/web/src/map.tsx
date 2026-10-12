import 'leaflet/dist/leaflet.css'
import L from 'leaflet'
import type { ComponentChildren } from 'preact'
import { useEffect, useRef } from 'preact/hooks'
import { categoryColor, categoryLabel } from './categories'
import type { Place, Prio } from './types'

export type ColorBy = 'prio' | 'category'
export const PRIO_COLOR: Record<Prio, string> = { Muss: '#c62828', Gerne: '#e08a00', 'Falls Zeit': '#1e6fd0', Flughafen: '#6b7280' }

export const colorOf = (p: Place, by: ColorBy) => (by === 'prio' ? PRIO_COLOR[p.prio] : categoryColor(p.category || 'other'))

/** The legend for what is on the map right now: only values that occur. */
export function Legend(props: { places: Place[]; by: ColorBy }) {
  const entries = props.by === 'prio'
    ? (Object.keys(PRIO_COLOR) as Prio[]).filter((p) => props.places.some((x) => x.prio === p)).map((p) => [p, PRIO_COLOR[p]] as const)
    : [...new Set(props.places.map((p) => p.category || 'other'))].map((c) => [categoryLabel(c), categoryColor(c)] as const)
  return <div class="legends">{entries.map(([label, color]) => <span class="legend"><i style={{ background: color }} />{label}</span>)}</div>
}

/** The Leaflet map in a box: OpenStreetMap tiles, mouse wheel zoom, and it learns when its box changes size (large view, rotating the phone). */
export function useLeafletMap() {
  const element = useRef<HTMLDivElement>(null)
  const map = useRef<L.Map | null>(null)
  const layer = useRef<L.LayerGroup | null>(null)
  useEffect(() => {
    const created = L.map(element.current!, { scrollWheelZoom: true, zoomSnap: 0.5, zoomDelta: 0.5, wheelPxPerZoomLevel: 90 }).setView([36.2, 138.2], 5)
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 18, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
    }).addTo(created)
    layer.current = L.layerGroup().addTo(created)
    map.current = created
    const observer = new ResizeObserver(() => created.invalidateSize({ animate: false }))
    observer.observe(element.current!)
    return () => { observer.disconnect(); created.remove(); map.current = null }
  }, [])
  return { element, map, layer }
}

/** The map box with its buttons. "Vergrößern" opens it over the whole page (Escape closes it again). */
export function MapFrame(props: { element: preact.RefObject<HTMLDivElement>; label: string; expanded: boolean; onExpand: (expanded: boolean) => void;
  onFit: () => void; fitLabel?: string; children?: ComponentChildren }) {
  useEffect(() => {
    if (!props.expanded) return
    const close = (event: KeyboardEvent) => { if (event.key === 'Escape') props.onExpand(false) }
    document.addEventListener('keydown', close)
    document.body.classList.add('map-open')
    return () => { document.removeEventListener('keydown', close); document.body.classList.remove('map-open') }
  }, [props.expanded])
  return (
    <div class={`mapwrap${props.expanded ? ' expanded' : ''}`}>
      <div ref={props.element} id="map" role="img" aria-label={props.label} />
      <div class="map-tools">
        <button type="button" class="map-btn" onClick={props.onFit}>{props.fitLabel ?? 'Auf Auswahl zoomen'}</button>
        <button type="button" class="map-btn" aria-pressed={props.expanded} onClick={() => props.onExpand(!props.expanded)}>
          {props.expanded ? 'Verkleinern' : 'Vergrößern'}
        </button>
      </div>
      {props.children}
    </div>
  )
}

/** The map of the ideas: coloured by priority or category; a place picked on the map is handed to the parent. */
export function IdeasMap(props: {
  places: Place[]
  colorBy: ColorBy
  focused: string | null
  fitKey: string
  expanded: boolean
  onExpand: (expanded: boolean) => void
  onPick: (id: string) => void
  children?: ComponentChildren
}) {
  const { element, map, layer } = useLeafletMap()
  const fitted = useRef('')
  const latest = useRef(props)
  latest.current = props

  const fit = (places: Place[]) => {
    const shown = places.filter((p) => p.has_coordinate)
    if (!map.current || shown.length === 0) return
    // Far-away airports would shrink the real destinations to a dot, so frame the places first.
    const framed = shown.filter((p) => p.prio !== 'Flughafen')
    map.current.fitBounds(L.latLngBounds((framed.length ? framed : shown).map((p) => [p.latitude, p.longitude] as [number, number])), { padding: [32, 32], maxZoom: 14, animate: false })
  }

  useEffect(() => {
    if (!map.current || !layer.current) return
    layer.current.clearLayers()
    for (const place of props.places.filter((p) => p.has_coordinate)) {
      const selected = place.id === props.focused
      L.circleMarker([place.latitude, place.longitude], {
        radius: selected ? 12 : 7, color: selected ? '#111' : '#fff', weight: selected ? 3 : 2,
        fillColor: colorOf(place, props.colorBy), fillOpacity: place.decision === 'Nein' ? 0.4 : 0.95,
      }).addTo(layer.current).bindTooltip(place.name).on('click', () => latest.current.onPick(place.id))
    }
    if (fitted.current !== props.fitKey) { fit(props.places); fitted.current = props.fitKey }
  }, [props.places, props.focused, props.colorBy, props.fitKey])

  useEffect(() => {
    const place = props.places.find((p) => p.id === props.focused)
    if (place?.has_coordinate && map.current) map.current.setView([place.latitude, place.longitude], Math.max(map.current.getZoom(), 11), { animate: false })
  }, [props.focused])

  return <MapFrame element={element} label="Karte der Ideen" expanded={props.expanded} onExpand={props.onExpand} onFit={() => fit(props.places)}>{props.children}</MapFrame>
}
