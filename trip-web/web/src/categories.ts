/** What kind of thing an idea is. The ids and labels are the same as in app/categories.py (a test checks that); the colours are for the map. */
export const CATEGORIES = [
  { id: 'temple', label: 'Tempel & Schrein', color: '#b03a2e' },
  { id: 'sight', label: 'Sehenswürdigkeit', color: '#2874a6' },
  { id: 'museum', label: 'Museum & Kunst', color: '#7d3c98' },
  { id: 'nature', label: 'Natur & Berge', color: '#1e8449' },
  { id: 'food', label: 'Essen & Märkte', color: '#ca6f1e' },
  { id: 'shopping', label: 'Shopping', color: '#c2185b' },
  { id: 'activity', label: 'Aktivität & Erlebnis', color: '#00838f' },
  { id: 'event', label: 'Fest & Feuerwerk', color: '#6d4c41' },
  { id: 'nightlife', label: 'Abend & Nachtleben', color: '#283593' },
  { id: 'transport', label: 'Anreise & Flughafen', color: '#616161' },
  { id: 'other', label: 'Sonstiges', color: '#9e9e9e' },
] as const

export type CategoryId = (typeof CATEGORIES)[number]['id']

const BY_ID = new Map<string, (typeof CATEGORIES)[number]>(CATEGORIES.map((c) => [c.id, c]))

export const categoryLabel = (id: string) => BY_ID.get(id)?.label ?? 'Ohne Kategorie'
export const categoryColor = (id: string) => BY_ID.get(id)?.color ?? '#9e9e9e'
