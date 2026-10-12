import { describe, expect, it } from 'vitest'
import {
  activeCount, clearFilter, deserialize, durationBucket, facetCounts, filterPlaces, groupByRegion, matches, newFilter, serialize, sortPlaces, tokens,
} from './filters'
import type { Place } from './types'

let n = 0
const place = (over: Partial<Place>): Place => ({
  id: `p${++n}`, nr: '', name: 'Ort', region: '', category: 'sight', description: '', duration: '', heat: '', for_whom: '', prio: 'Gerne', decision: 'Offen',
  wished_by: '', source: '', notes: '', website: '', latitude: 0, longitude: 0, has_coordinate: false, sort_order: n, ...over,
} as Place)

const places = [
  place({ name: 'Asakusa mit Senso-ji', region: 'Tokyo', category: 'temple', prio: 'Muss', duration: '½ Tag', for_whom: 'A', has_coordinate: true, sort_order: 1 }),
  place({ name: 'Akihabara', region: 'Tokyo', category: 'shopping', prio: 'Muss', duration: '½ Tag', for_whom: 'J, E', sort_order: 2 }),
  place({ name: 'Fushimi Inari', region: 'Kyoto', category: 'temple', prio: 'Muss', duration: '½ Tag', for_whom: 'A', sort_order: 3 }),
  place({ name: 'Kamikochi', region: 'Alpen', category: 'nature', prio: 'Gerne', duration: '1 Tag', decision: 'Nein', for_whom: 'E, J', sort_order: 4 }),
  place({ name: 'Hakone', region: 'Tokyo-Umgebung', category: 'activity', prio: 'Gerne', duration: '1–2 Tage', sort_order: 5 }),
  place({ name: 'Flughafen Haneda (HND)', region: 'Flughafen', category: 'transport', prio: 'Flughafen', sort_order: 6 }),
  place({ name: 'Ohne Region', region: '', category: '' as never, sort_order: 7, wished_by: 'Aaron, Mama' }),
]

describe('duration buckets', () => {
  it.each([
    ['½ Tag', '½ Tag'], ['½–1 Tag', '½ Tag'], ['½ Tag, Abend', '½ Tag'], ['1 Tag', '1 Tag'], ['1–2 Tage', 'Mehrere Tage'], ['2 Tage', 'Mehrere Tage'],
    ['3+ Tage', 'Mehrere Tage'], ['1–2 Tage', 'Mehrere Tage'], ['Abend', 'Abend'], ['Abende', 'Abend'], ['1–2 Std.', 'Stunden'], ['2 Std.', 'Stunden'], ['', 'Unbekannt'], ['bald', 'Unbekannt'],
  ])('%s is %s', (text, bucket) => expect(durationBucket(text)).toBe(bucket))
})

describe('filtering', () => {
  it('shows everything except rejected places by default', () => {
    expect(filterPlaces(places, newFilter()).map((p) => p.name)).not.toContain('Kamikochi')
    expect(filterPlaces(places, newFilter())).toHaveLength(6)
  })

  it('an empty group means everything, a chosen group means only those', () => {
    const f = { ...clearFilter(newFilter()), regions: new Set(['Tokyo', 'Kyoto']) }
    expect(filterPlaces(places, f).map((p) => p.name)).toEqual(['Asakusa mit Senso-ji', 'Akihabara', 'Fushimi Inari'])
  })

  it('combines groups with AND and values inside a group with OR', () => {
    const f = { ...clearFilter(newFilter()), regions: new Set(['Tokyo', 'Kyoto']), categories: new Set(['temple']) }
    expect(filterPlaces(places, f).map((p) => p.name)).toEqual(['Asakusa mit Senso-ji', 'Fushimi Inari'])
  })

  it('searches every word in the name, region, category, notes and more, ignoring case and accents', () => {
    const f = { ...clearFilter(newFilter()), q: 'TEMPEL kyoto' }          // category label "Tempel & Schrein" + region
    expect(filterPlaces(places, f).map((p) => p.name)).toEqual(['Fushimi Inari'])
    expect(filterPlaces(places, { ...clearFilter(newFilter()), q: 'sehenswurdigkeit' })).toHaveLength(0)
    expect(filterPlaces(places, { ...clearFilter(newFilter()), q: 'sehenswürdigkeit' })).toHaveLength(0)    // nobody here is a plain sight
  })

  it('finds places by who they are for and who wished them, even with several people in one field', () => {
    expect(filterPlaces(places, { ...clearFilter(newFilter()), forWhom: new Set(['J']) }).map((p) => p.name)).toEqual(['Akihabara', 'Kamikochi'])
    expect(filterPlaces(places, { ...clearFilter(newFilter()), wishedBy: new Set(['Mama']) }).map((p) => p.name)).toEqual(['Ohne Region'])
    expect(tokens('J, E')).toEqual(['J', 'E'])
  })

  it('treats a missing region or category as its own value', () => {
    const f = { ...clearFilter(newFilter()), regions: new Set(['Ohne Region']), categories: new Set(['other']) }
    expect(filterPlaces(places, f).map((p) => p.name)).toEqual(['Ohne Region'])
  })

  it('can limit to places that are on the map', () => {
    expect(filterPlaces(places, { ...clearFilter(newFilter()), positionOnly: true }).map((p) => p.name)).toEqual(['Asakusa mit Senso-ji'])
  })

  it('counts active filters, and clearing keeps the sort and the grouping', () => {
    expect(activeCount(newFilter())).toBe(2)                                 // Offen and Ja
    const f = { ...newFilter(), q: 'x', positionOnly: true, sort: 'name' as const, group: true }
    expect(activeCount(f)).toBe(4)
    const cleared = clearFilter(f)
    expect(activeCount(cleared)).toBe(0)
    expect([cleared.sort, cleared.group]).toEqual(['name', true])
  })
})

describe('facet counts', () => {
  it('say how many places a value would show given the other groups', () => {
    const f = { ...newFilter(), categories: new Set(['temple']) }
    const regions = Object.fromEntries(facetCounts(places, f, 'regions'))
    expect(regions).toMatchObject({ Tokyo: 1, Kyoto: 1, Alpen: 0, 'Tokyo-Umgebung': 0 })   // only temples; Alpen is rejected as well
    const categories = Object.fromEntries(facetCounts(places, { ...newFilter(), regions: new Set(['Tokyo']) }, 'categories'))
    expect(categories).toMatchObject({ temple: 1, shopping: 1, nature: 0 })                 // the category group ignores itself but not the region
  })

  it('keep a selected value in the list even when it gives nothing now', () => {
    const f = { ...newFilter(), regions: new Set(['Atlantis']) }
    expect(Object.fromEntries(facetCounts(places, f, 'regions'))).toMatchObject({ Atlantis: 0 })
  })

  it('count the decision group without hiding Nein from its own count', () => {
    expect(Object.fromEntries(facetCounts(places, newFilter(), 'verdicts'))).toEqual({ Offen: 6, Nein: 1, Ja: 0 })
  })

  it('match the list: the numbers of a group add up to what the other groups allow', () => {
    const f = { ...newFilter(), prios: new Set(['Muss' as const]) }
    const total = facetCounts(places, f, 'regions').reduce((sum, [, count]) => sum + count, 0)
    expect(total).toBe(places.filter((p) => matches(p, f, 'regions')).length)
  })
})

describe('sorting and grouping', () => {
  it('sorts by priority, then the order of the list', () => {
    expect(sortPlaces(places, 'prio').map((p) => p.name).slice(0, 3)).toEqual(['Asakusa mit Senso-ji', 'Akihabara', 'Fushimi Inari'])
  })

  it('sorts by name the German way and by category in the order of the list of categories', () => {
    expect(sortPlaces(places, 'name')[0].name).toBe('Akihabara')
    expect(sortPlaces(places, 'category').map((p) => p.category)).toEqual(['temple', 'temple', 'nature', 'shopping', 'activity', 'transport', ''].sort((a, b) =>
      ['temple', 'sight', 'museum', 'nature', 'food', 'shopping', 'activity', 'event', 'nightlife', 'transport', 'other'].indexOf(a || 'other') -
      ['temple', 'sight', 'museum', 'nature', 'food', 'shopping', 'activity', 'event', 'nightlife', 'transport', 'other'].indexOf(b || 'other')))
  })

  it('groups by region in order of first appearance and puts places without a region last', () => {
    const groups = groupByRegion(sortPlaces(places, 'order'))
    expect(groups.map((g) => g.region)).toEqual(['Tokyo', 'Kyoto', 'Alpen', 'Tokyo-Umgebung', 'Flughafen', 'Ohne Region'])
    expect(groups[0].places.map((p) => p.name)).toEqual(['Asakusa mit Senso-ji', 'Akihabara'])
  })
})

describe('remembering the filter', () => {
  it('survives a round trip', () => {
    const f = { ...newFilter(), q: 'tempel', regions: new Set(['Kyoto']), prios: new Set(['Muss' as const]), positionOnly: true, sort: 'region' as const, group: true }
    const back = deserialize(serialize(f))
    expect(back).toEqual(f)
  })

  it('falls back to the default for nothing, rubbish or an old format', () => {
    expect(deserialize(null)).toEqual(newFilter())
    expect(deserialize('{kaputt')).toEqual(newFilter())
    expect(deserialize(JSON.stringify({ sort: 'unbekannt', regions: 'Kyoto', q: 5 }))).toEqual(newFilter())
  })
})

describe('sorting by popularity', () => {
  const mk = (id: string, name: string, order: number) => ({ id, name, sort_order: order, prio: 'Gerne', region: '', category: 'sight', duration: '' }) as never
  it('puts the most liked first and keeps the list order for equal scores', () => {
    const list = [mk('a', 'A', 1), mk('b', 'B', 2), mk('c', 'C', 3)]
    expect(sortPlaces(list, 'votes', { c: 3, b: 1 }).map((p: { id: string }) => p.id)).toEqual(['c', 'b', 'a'])
    expect(sortPlaces(list, 'votes').map((p: { id: string }) => p.id)).toEqual(['a', 'b', 'c'])
  })
})
