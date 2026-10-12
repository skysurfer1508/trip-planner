import type { BudgetSummary, Timeline, FoundPlace, ImportPreview, Person, Role, RouteSummary, Trip, TripData, TripSummary } from './types'

export class ApiError extends Error {}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(path, { credentials: 'same-origin', ...init })
  if (response.status === 401) {
    location.href = `/login?next=${encodeURIComponent(location.pathname)}`
    throw new ApiError('Nicht angemeldet')
  }
  if (!response.ok) {
    const body = await response.json().catch(() => ({}))
    throw new ApiError(typeof body.detail === 'string' ? body.detail : `Fehler ${response.status}`)
  }
  return response.json() as Promise<T>
}

/** Changing calls carry this header; the server refuses them without it (protection against forged requests from other sites). */
const WRITE = { 'Content-Type': 'application/json', 'X-Trip-Client': '1' }
const send = (method: string, body?: unknown): RequestInit => ({ method, headers: WRITE, body: body === undefined ? undefined : JSON.stringify(body) })

/** What a day-plan operation answers: the history entry that can undo it (none if nothing needed to change). */
export interface Done { change_id: string | null; [key: string]: unknown }

export type TripFields = Partial<Omit<Trip, 'id'>> & { destination_latitude?: number; destination_longitude?: number }

export const api = {
  me: () => request<{ name: string; sub: string; people: string[] }>('/api/me'),
  trips: () => request<TripSummary[]>('/api/trips'),
  data: (tripId: string) => request<TripData>(`/api/trips/${encodeURIComponent(tripId)}/data`),
  revision: () => request<{ revision: number }>('/api/revision'),

  createTrip: (fields: TripFields) => request<{ trip_id: string }>('/api/trips', send('POST', fields)),
  updateTrip: (tripId: string, data: TripFields) => request<Trip>(`/api/trips/${tripId}`, send('PATCH', { data })),
  deleteTrip: (tripId: string) => request<{ ok: boolean }>(`/api/trips/${tripId}`, send('DELETE')),

  patch: (entity: string, id: string, data: Record<string, unknown>) => request(`/api/items/${entity}/${encodeURIComponent(id)}`, send('PATCH', { data })),
  createItem: (tripId: string, entity: string, data: Record<string, unknown>) => request<Done & { id: string }>(`/api/trips/${tripId}/items/${entity}`, send('POST', { data })),
  deleteItem: (entity: string, id: string) => request<Done>(`/api/items/${entity}/${encodeURIComponent(id)}`, send('DELETE')),
  searchPlaces: (q: string, near?: [number, number]) =>
    request<FoundPlace[]>(`/api/search/places?q=${encodeURIComponent(q)}${near ? `&near=${near[0]},${near[1]}` : ''}`),
  moveStop: (stopId: string, where: { index?: number; day_id?: string }) => request<Done>(`/api/stops/${stopId}/move`, send('POST', where)),
  duplicateStop: (stopId: string) => request<Done>(`/api/stops/${stopId}/duplicate`, send('POST')),
  copyDay: (dayId: string, toDayId: string) => request<Done>(`/api/days/${dayId}/copy`, send('POST', { to_day_id: toDayId })),
  sortDay: (dayId: string) => request<Done>(`/api/days/${dayId}/sort`, send('POST')),
  optimizeDay: (dayId: string) => request<Done>(`/api/days/${dayId}/optimize`, send('POST')),
  retimeDay: (dayId: string, start?: string) => request<Done>(`/api/days/${dayId}/retime`, send('POST', { start })),
  bookingStops: (tripId: string) => request<Done & { added: number; skipped_without_position: number }>(`/api/trips/${tripId}/booking-stops`, send('POST')),
  placeToDay: (placeId: string, dayId: string) => request<Done>(`/api/places/${placeId}/to-day`, send('POST', { day_id: dayId })),
  budget: (tripId: string) => request<BudgetSummary>(`/api/trips/${tripId}/budget`),
  packingTemplate: (tripId: string, options: Record<string, unknown>) => request<Done & { added: number }>(`/api/trips/${tripId}/packing-template`, send('POST', options)),
  packingReset: (tripId: string) => request<Done>(`/api/trips/${tripId}/packing/reset`, send('POST')),
  packingClear: (tripId: string) => request<Done>(`/api/trips/${tripId}/packing/clear`, send('POST')),
  route: (tripId: string) => request<RouteSummary>(`/api/trips/${tripId}/route`),
  legPath: (legId: string) => request<{ path: [number, number][] | null; source?: string }>(`/api/legs/${legId}/path`),
  timeline: (tripId: string) => request<Timeline>(`/api/trips/${tripId}/timeline`),
  vote: (placeId: string, value: -1 | 0 | 1) => request<{ ok: boolean }>(`/api/places/${placeId}/vote`, send('PUT', { value })),
  chooseLeg: (legId: string) => request<Done>(`/api/legs/${legId}/choose`, send('POST')),
  moveHop: (tripId: string, hop: number, delta: 1 | -1) => request<Done>(`/api/trips/${tripId}/hops/${hop}/move`, send('POST', { delta })),
  undo: (changeId: string) => request(`/api/changes/${encodeURIComponent(changeId)}/undo`, send('POST')),

  people: (q: string) => request<Person[]>(`/api/people?q=${encodeURIComponent(q)}`),
  setMember: (tripId: string, sub: string, role: Role) => request(`/api/trips/${tripId}/members/${encodeURIComponent(sub)}`, send('PUT', { role })),
  removeMember: (tripId: string, sub: string) => request(`/api/trips/${tripId}/members/${encodeURIComponent(sub)}`, send('DELETE')),

  importPreview: (archive: unknown, timeZone: string) => request<ImportPreview>('/api/import', send('POST', { archive, time_zone: timeZone, preview: true })),
  importTrips: (archive: unknown, timeZone: string) => request<{ trips: { trip_id: string; name: string }[] }>('/api/import', send('POST', { archive, time_zone: timeZone })),
  exportIcsUrl: (tripId: string, timeZone: string) => `/api/trips/${encodeURIComponent(tripId)}/export.ics?tz=${encodeURIComponent(timeZone)}`,
  exportTextUrl: (tripId: string) => `/api/trips/${encodeURIComponent(tripId)}/export.txt`,
  exportUrl: (tripId: string, timeZone: string) => `/api/trips/${encodeURIComponent(tripId)}/export.tripplanner?tz=${encodeURIComponent(timeZone)}`,
}
