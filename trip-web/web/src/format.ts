const ESCAPES: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }

/** Everything the family or Claude typed goes through this before it reaches innerHTML. */
export function esc(value: unknown): string {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ESCAPES[c])
}

/** Only http(s) links are clickable; anything else (javascript:, data:) is dropped. */
export function safeUrl(value: string): string {
  try {
    const url = new URL(value)
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : ''
  } catch {
    return ''
  }
}

/** The Google Maps page of a place. With a position, the search is centred there so a common name ("Park") finds the right one; without, name and address do. */
export function mapsUrl(place: { name: string; address?: string; latitude?: number; longitude?: number }): string {
  const located = !!(place.latitude || place.longitude)
  if (located) return `https://www.google.com/maps/search/${encodeURIComponent(place.name)}/@${place.latitude},${place.longitude},17z`
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent([place.name, place.address].filter(Boolean).join(' '))}`
}

// Dates and times are the local wall-clock time of the place ("2027-07-20T09:30"), so nothing is converted between time zones.
function parts(local: string): Date {
  const [y, m, d] = local.slice(0, 10).split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d))
}

export function dayLabel(local: string): string {
  return new Intl.DateTimeFormat('de-DE', { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'UTC' }).format(parts(local))
}

export function shortDate(local: string): string {
  return new Intl.DateTimeFormat('de-DE', { day: 'numeric', month: 'short', timeZone: 'UTC' }).format(parts(local))
}

export function timeLabel(local: string): string {
  return local.slice(11, 16)
}

export function dateTimeLabel(local: string): string {
  return `${shortDate(local)}, ${timeLabel(local)}`
}

export function money(amount: number, currency: string): string {
  try {
    return new Intl.NumberFormat('de-DE', { style: 'currency', currency }).format(amount)
  } catch {
    return `${amount.toFixed(2)} ${currency}`
  }
}

/** For log entries, which are stored in UTC. */
export function ago(iso: string): string {
  const minutes = Math.round((Date.now() - new Date(iso).getTime()) / 60000)
  if (minutes < 1) return 'gerade eben'
  if (minutes < 60) return `vor ${minutes} Min.`
  const hours = Math.round(minutes / 60)
  if (hours < 24) return `vor ${hours} Std.`
  return `vor ${Math.round(hours / 24)} Tg.`
}
