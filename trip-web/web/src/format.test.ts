import { describe, expect, it } from 'vitest'
import { mapsUrl } from './format'

describe('mapsUrl', () => {
  it('centres the search on the position when there is one', () => {
    expect(mapsUrl({ name: 'Senso-ji', latitude: 35.7148, longitude: 139.7967 })).toBe('https://www.google.com/maps/search/Senso-ji/@35.7148,139.7967,17z')
  })
  it('escapes the name', () => {
    expect(mapsUrl({ name: 'Café & Bar/Terrasse', latitude: 47.37, longitude: 8.54 })).toContain('/search/Caf%C3%A9%20%26%20Bar%2FTerrasse/@47.37,8.54')
  })
  it('searches by name and address when the place has no position', () => {
    const url = new URL(mapsUrl({ name: 'Hotel Sonne', address: 'Bahnhofstrasse 1, Zürich', latitude: 0, longitude: 0 }))
    expect(url.searchParams.get('query')).toBe('Hotel Sonne Bahnhofstrasse 1, Zürich')
    expect(url.searchParams.get('api')).toBe('1')
  })
})
