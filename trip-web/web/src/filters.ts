import { categoryLabel } from './categories'
import type { Place, Prio, Verdict } from './types'

/** Filtering, sorting and grouping of the ideas. Pure functions, so they can be tested without a browser. */

export const PRIOS: Prio[] = ['Muss', 'Gerne', 'Falls Zeit', 'Flughafen']
export const VERDICTS: Verdict[] = ['Offen', 'Ja', 'Nein']
export const DURATIONS = ['Abend', 'Stunden', '½ Tag', '1 Tag', 'Mehrere Tage', 'Unbekannt'] as const
export type DurationBucket = (typeof DURATIONS)[number]

export type SortKey = 'order' | 'prio' | 'name' | 'region' | 'category' | 'duration' | 'votes'
export const SORTS: [SortKey, string][] = [
  ['order', 'Reihenfolge der Liste'], ['prio', 'Priorität'], ['name', 'Name'], ['region', 'Region'], ['category', 'Kategorie'], ['duration', 'Dauer'], ['votes', 'Beliebtheit (Stimmen)'],
]

export type Facet = 'regions' | 'categories' | 'prios' | 'verdicts' | 'durations' | 'forWhom' | 'wishedBy'

export interface IdeaFilter {
  q: string
  regions: Set<string>
  categories: Set<string>
  prios: Set<Prio>
  verdicts: Set<Verdict>
  durations: Set<DurationBucket>
  forWhom: Set<string>
  wishedBy: Set<string>
  positionOnly: boolean
  sort: SortKey
  group: boolean
}

export const NO_REGION = 'Ohne Region'

/** Nothing selected in a group means "everything"; only the decision starts with Offen and Ja so that rejected places stay out of the way. */
export function newFilter(): IdeaFilter {
  return {
    q: '', regions: new Set(), categories: new Set(), prios: new Set(), verdicts: new Set<Verdict>(['Offen', 'Ja']), durations: new Set(),
    forWhom: new Set(), wishedBy: new Set(), positionOnly: false, sort: 'order', group: false,
  }
}

/** Clears every filter but keeps how the list is sorted and grouped. */
export function clearFilter(filter: IdeaFilter): IdeaFilter {
  return { ...newFilter(), verdicts: new Set(), sort: filter.sort, group: filter.group }
}

export function activeCount(filter: IdeaFilter): number {
  return (filter.q.trim() ? 1 : 0) + filter.regions.size + filter.categories.size + filter.prios.size + filter.verdicts.size + filter.durations.size
    + filter.forWhom.size + filter.wishedBy.size + (filter.positionOnly ? 1 : 0)
}

const fold = (text: string) => text.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()

/** How long a place takes, in the few steps people plan with. The dates are free text ("½ Tag", "1–2 Std.", "3+ Tage", "Abend"). */
export function durationBucket(text: string): DurationBucket {
  const t = fold(text)
  if (!t.trim()) return 'Unbekannt'
  if (t.includes('½') || /\b0[.,]5\s*tag/.test(t)) return '½ Tag'
  if (/tage\b/.test(t) || /\d\s*\+\s*tag/.test(t)) return 'Mehrere Tage'
  if (/\b1\s*tag\b/.test(t)) return '1 Tag'
  if (t.includes('abend')) return 'Abend'
  if (/std|stunde/.test(t)) return 'Stunden'
  return 'Unbekannt'
}

/** "J, E" gives ["J", "E"]: several people or groups in one field. */
export function tokens(text: string): string[] {
  return text.split(/[,;/]+/).map((t) => t.trim()).filter(Boolean)
}

const regionOf = (p: Place) => p.region || NO_REGION
const categoryOf = (p: Place) => p.category || 'other'

function haystack(p: Place): string {
  return fold([p.name, p.region, categoryLabel(categoryOf(p)), p.description, p.notes, p.heat, p.duration, p.for_whom, p.wished_by, p.source].join(' '))
}

const passes = (selected: Set<string>, values: string[]) => selected.size === 0 || values.some((v) => selected.has(v))

/** Whether a place passes every group of the filter, optionally ignoring one group (to count what choosing a value there would give). */
export function matches(p: Place, f: IdeaFilter, skip?: Facet): boolean {
  if (f.q.trim()) {
    const text = haystack(p)
    if (!fold(f.q).split(/\s+/).filter(Boolean).every((word) => text.includes(word))) return false
  }
  if (f.positionOnly && !p.has_coordinate) return false
  return (skip === 'regions' || passes(f.regions, [regionOf(p)]))
    && (skip === 'categories' || passes(f.categories, [categoryOf(p)]))
    && (skip === 'prios' || passes(f.prios, [p.prio]))
    && (skip === 'verdicts' || passes(f.verdicts, [p.decision]))
    && (skip === 'durations' || passes(f.durations, [durationBucket(p.duration)]))
    && (skip === 'forWhom' || passes(f.forWhom, tokens(p.for_whom)))
    && (skip === 'wishedBy' || passes(f.wishedBy, tokens(p.wished_by)))
}

export const filterPlaces = (places: Place[], f: IdeaFilter) => places.filter((p) => matches(p, f))

/** The values a group offers and how many places each would show, given all the OTHER groups (so the numbers say what a tap gives). */
export function facetCounts(places: Place[], f: IdeaFilter, facet: Facet): [string, number][] {
  const counts = new Map<string, number>()
  const valuesOf = (p: Place): string[] => {
    switch (facet) {
      case 'regions': return [regionOf(p)]
      case 'categories': return [categoryOf(p)]
      case 'prios': return [p.prio]
      case 'verdicts': return [p.decision]
      case 'durations': return [durationBucket(p.duration)]
      case 'forWhom': return tokens(p.for_whom)
      case 'wishedBy': return tokens(p.wished_by)
    }
  }
  for (const p of places) {
    const shown = matches(p, f, facet)
    for (const v of new Set(valuesOf(p))) counts.set(v, (counts.get(v) ?? 0) + (shown ? 1 : 0))
  }
  // Selected values stay in the list even when they now give nothing, so they can be switched off again.
  for (const v of f[facet] as Set<string>) if (!counts.has(v)) counts.set(v, 0)
  return [...counts]
}

const rank = <T,>(order: readonly T[], value: T) => { const i = order.indexOf(value); return i < 0 ? order.length : i }
const byName = (a: Place, b: Place) => a.name.localeCompare(b.name, 'de')

/** `score` is the number of votes for minus against, per place id (only used for the sort by popularity). */
export function sortPlaces(places: Place[], key: SortKey, score: Record<string, number> = {}): Place[] {
  const list = [...places]
  const tie = (a: Place, b: Place) => (a.sort_order - b.sort_order) || byName(a, b)
  const categories = ['temple', 'sight', 'museum', 'nature', 'food', 'shopping', 'activity', 'event', 'nightlife', 'transport', 'other']
  const comparators: Record<SortKey, (a: Place, b: Place) => number> = {
    order: tie,
    prio: (a, b) => rank(PRIOS, a.prio) - rank(PRIOS, b.prio) || tie(a, b),
    name: byName,
    region: (a, b) => regionOf(a).localeCompare(regionOf(b), 'de') || tie(a, b),
    category: (a, b) => rank(categories, categoryOf(a)) - rank(categories, categoryOf(b)) || tie(a, b),
    duration: (a, b) => rank(DURATIONS, durationBucket(a.duration)) - rank(DURATIONS, durationBucket(b.duration)) || tie(a, b),
    votes: (a, b) => (score[b.id] ?? 0) - (score[a.id] ?? 0) || tie(a, b),
  }
  return list.sort(comparators[key])
}

export interface Group { region: string; places: Place[] }

/** Regions in the order they first appear in the (sorted) list; places without a region come last. */
export function groupByRegion(places: Place[]): Group[] {
  const groups = new Map<string, Place[]>()
  for (const p of places) groups.set(regionOf(p), [...(groups.get(regionOf(p)) ?? []), p])
  return [...groups].map(([region, list]) => ({ region, places: list })).sort((a, b) => Number(a.region === NO_REGION) - Number(b.region === NO_REGION))
}

// MARK: Remembering the filter (per trip, in this browser only)

type Stored = Omit<IdeaFilter, 'regions' | 'categories' | 'prios' | 'verdicts' | 'durations' | 'forWhom' | 'wishedBy'> & Record<Facet, string[]>
const FACETS: Facet[] = ['regions', 'categories', 'prios', 'verdicts', 'durations', 'forWhom', 'wishedBy']

export function serialize(f: IdeaFilter): string {
  const out: Record<string, unknown> = { ...f }
  for (const facet of FACETS) out[facet] = [...(f[facet] as Set<string>)]
  return JSON.stringify(out)
}

export function deserialize(text: string | null): IdeaFilter {
  const base = newFilter()
  if (!text) return base
  try {
    const raw = JSON.parse(text) as Partial<Stored>
    const out: IdeaFilter = { ...base }
    for (const facet of FACETS) if (Array.isArray(raw[facet])) (out[facet] as Set<string>) = new Set(raw[facet]!.map(String))
    if (typeof raw.q === 'string') out.q = raw.q
    if (typeof raw.positionOnly === 'boolean') out.positionOnly = raw.positionOnly
    if (typeof raw.group === 'boolean') out.group = raw.group
    if (SORTS.some(([k]) => k === raw.sort)) out.sort = raw.sort as SortKey
    return out
  } catch {
    return base
  }
}
