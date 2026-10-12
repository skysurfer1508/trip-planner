export type Prio = 'Muss' | 'Gerne' | 'Falls Zeit' | 'Flughafen'
export type Verdict = 'Offen' | 'Ja' | 'Nein'
export type Role = 'owner' | 'editor' | 'viewer'
export type Phase = 'planning' | 'building'

export interface TripSummary {
  id: string
  name: string
  destination?: string
  start_date: string
  end_date: string
  currency_code: string
  budget?: number
  phase: Phase
  role: Role
}

export interface Trip {
  id: string
  name: string
  destination: string
  start_date: string
  end_date: string
  currency_code: string
  budget: number
  description: string
  time_zone: string
  transport_raw: 'walking' | 'transit' | 'car'
  phase: Phase
  travelers: number
  country_code?: string
  destination_latitude?: number
  destination_longitude?: number
}

export interface Member {
  name: string
  role: Role
  sub?: string
  username?: string
}

export interface Person {
  sub: string
  name: string
  username: string
}

export interface Place {
  id: string
  nr: string
  name: string
  region: string
  category: string
  description: string
  duration: string
  heat: string
  for_whom: string
  prio: Prio
  decision: Verdict
  wished_by: string
  source: string
  notes: string
  website: string
  latitude: number
  longitude: number
  has_coordinate: boolean
  sort_order: number
}

export interface Decision {
  id: string
  kind: 'decided' | 'open'
  title: string
  detail: string
}

export interface Day {
  id: string
  date: string
  notes: string
}

export interface Stop {
  id: string
  day_id: string
  name: string
  address: string
  category_raw: string
  planned_time: string | null
  duration_minutes: number
  notes: string
  sort_order: number
  is_done: boolean
  estimated_cost: number
  website: string
  phone: string
  opening_hours: string
  latitude: number
  longitude: number
  place_id?: string
}

export interface Booking {
  id: string
  kind_raw: string
  title: string
  start_date: string
  end_date: string
  place_name: string
  other_end: string
  address: string
  reference: string
  notes: string
  buffer_minutes: number
  remind: boolean
  phone: string
  website: string
  latitude: number
  longitude: number
  has_coordinate: boolean
}

export interface Expense {
  id: string
  title: string
  amount: number
  currency_code: string
  category_raw: string
  date: string
}

export interface ChecklistItem {
  id: string
  title: string
  section: string
  is_done: boolean
}

export interface ChangeEntry {
  id: string
  summary: string
  actor?: string
  via: 'web' | 'claude' | 'import' | 'app'
  created_at: string
  undone_at?: string
}

export interface DayWindow {
  start: string | null
  end: string | null
  hotel: string | null
  items: { time: string | null; text: string }[]
}

export interface TripData {
  trip: Trip
  role: Role
  members: Member[]
  places: Place[]
  decisions: Decision[]
  days: Day[]
  stops: Stop[]
  bookings: Booking[]
  expenses: Expense[]
  checklist: ChecklistItem[]
  log: ChangeEntry[]
  windows: Record<string, DayWindow>
  legs: Leg[]
  stays: Stay[]
  votes: Vote[]
  me: string
  revision: number
}

export interface ImportPreview {
  time_zone: string
  trips: {
    name: string
    start_date: string
    end_date: string
    stops: number
    days_with_stops: number
    expenses: number
    checklist: number
    places: number
    bookings: number
    documents_skipped: number
    sample: { date: string; time: string; name: string }[]
  }[]
}

export interface FoundPlace {
  name: string
  address: string
  latitude: number
  longitude: number
  category_raw: string
  kind: string
}

export interface BudgetSummary {
  currency: string
  budget: number
  spent: number
  left: number
  percent: number | null
  over: boolean
  planned: number
  by_category: { category: string; total: number }[]
  by_day: { date: string; total: number }[]
  converted: Record<string, number | null>
  unconverted: { id: string; title: string; currency: string }[]
  rates_known: boolean
  planned_travel?: number
}

export interface Leg {
  id: string
  hop: number
  status: 'option' | 'chosen' | 'booked'
  from_name: string
  from_latitude: number
  from_longitude: number
  to_name: string
  to_latitude: number
  to_longitude: number
  mode: string
  line: string
  departure: string | null
  arrival: string | null
  duration_minutes: number
  price: number
  currency_code: string
  reference: string
  notes: string
  source: string
  source_url: string
  pass_ok?: number | boolean
}

export interface LegView extends Leg {
  mode_label: string
  price_in_trip_currency: number | null
  group_price: number | null
  /** The real way along rails or roads, when it has been looked up. */
  path?: [number, number][]
}

export interface RouteSummary {
  currency: string
  travelers: number
  hops: { hop: number; from_name: string; to_name: string; chosen: LegView | null; options: LegView[]; nearby: NearbyIdea[] }[]
  pass: PassComparison
  places: { name: string; latitude: number; longitude: number; has_position: boolean }[]
  total_minutes: number
  price_per_person: number
  price_for_group: number
  decided: number
  undecided: number[]
  warnings: string[]
}

export interface NearbyIdea {
  id: string
  name: string
  region: string
  category: string
  prio: Prio
  decision: Verdict
  distance_km: number
  along: number
}

export interface PassComparison {
  currency: string
  travelers: number
  price_list: string
  covered: number
  not_covered_paid: number
  singles_per_person: number
  singles_for_group: number
  span_days: number | null
  options: { days: number; price_per_person: number; price_for_group: number; fits: boolean | null; saves_for_group: number }[]
  best_days: number | null
  verdict: 'pass' | 'singles' | null
  notes: string[]
}

export interface Stay {
  id: string
  name: string
  nights: number
  latitude: number
  longitude: number
  notes: string
  sort_order: number
}

export interface Vote {
  place_id: string
  voter: string
  name: string
  value: 1 | -1
}

export interface TimelineStay {
  id: string
  name: string
  nights: number
  arrive: string
  leave: string
  notes: string
  arrival: { hop: number; mode: string; mode_label: string; line: string; duration_minutes: number; price_in_trip_currency: number | null; chosen: boolean } | null
  ideas: number
  must: number
  likes: number
}

export interface Timeline {
  start: string
  end: string
  available_nights: number
  planned_nights: number
  stays: TimelineStay[]
  warnings: string[]
  travel_days: string[]
}
