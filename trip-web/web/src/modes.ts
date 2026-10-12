/** Ways to get from one place to the next. The ids are the same as in app/entities.py (LEG_MODES); a test checks that. */
export const MODES = [
  { id: 'shinkansen', label: 'Shinkansen', color: '#c62828' },
  { id: 'train', label: 'Zug', color: '#1565c0' },
  { id: 'bus', label: 'Bus', color: '#2e7d32' },
  { id: 'flight', label: 'Flug', color: '#6a1b9a' },
  { id: 'ferry', label: 'Fähre', color: '#00838f' },
  { id: 'car', label: 'Auto', color: '#ef6c00' },
  { id: 'taxi', label: 'Taxi', color: '#f9a825' },
  { id: 'walk', label: 'zu Fuss', color: '#6d4c41' },
  { id: 'other', label: 'Sonstiges', color: '#757575' },
] as const

export type ModeId = (typeof MODES)[number]['id']
const BY_ID = new Map<string, (typeof MODES)[number]>(MODES.map((m) => [m.id, m]))
export const modeLabel = (id: string) => BY_ID.get(id)?.label ?? id
export const modeColor = (id: string) => BY_ID.get(id)?.color ?? '#757575'

/** 150 -> "2 Std. 30 Min.", 45 -> "45 Min.", 480 -> "8 Std.", 0 -> "". */
export function duration(minutes: number): string {
  if (!minutes || minutes < 0) return ''
  const h = Math.floor(minutes / 60), m = Math.round(minutes % 60)
  return [h ? `${h} Std.` : '', m ? `${m} Min.` : ''].filter(Boolean).join(' ')
}
