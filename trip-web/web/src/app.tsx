import { useCallback, useEffect, useRef, useState } from 'preact/hooks'
import { api } from './api'
import { shortDate } from './format'
import { DeleteDialog, ExportDialog, PHASE_LABEL, PhaseDialog, ShareDialog, TripForm, TripList } from './trips'
import type { Phase, TripData, TripSummary } from './types'
import { Menu, Notify, Skeleton, messageOf, useNotify, type ToastAction } from './ui'
import { Bookings, Budget, Packing } from './lists'
import { Plan } from './plan'
import { Route } from './route'
import { Timeline } from './timeline'
import { deserialize, serialize, type IdeaFilter } from './filters'
import { Ideas } from './ideas'
import { Decisions, Log, type ViewProps } from './views'
import { Icon } from './icons'

type Tab = 'ideas' | 'route' | 'timeline' | 'decisions' | 'plan' | 'bookings' | 'budget' | 'packing' | 'log'

const LABEL: Record<Tab, string> = {
  ideas: 'Ideen', route: 'Route', timeline: 'Zeitplan', decisions: 'Entscheide', plan: 'Plan', bookings: 'Buchungen', budget: 'Budget', packing: 'Packliste', log: 'Verlauf',
}

/** Planning is for collecting ideas and deciding; the day-by-day tools appear once the trip is being built. */
const TABS_FOR: Record<Phase, Tab[]> = {
  planning: ['ideas', 'route', 'timeline', 'decisions', 'log'],
  building: ['plan', 'route', 'timeline', 'ideas', 'bookings', 'budget', 'packing', 'decisions', 'log'],
}

/** The address bar is the router: `#/` is the list of trips, `#/trip/<id>/<tab>` is one trip. Back and reload keep working. */
function parseHash(): { tripId: string | null; tab: Tab | null } {
  const match = location.hash.match(/^#\/trip\/([^/]+)(?:\/(\w+))?/)
  const tab = (Object.keys(LABEL) as Tab[]).find((id) => id === match?.[2]) ?? null
  return { tripId: match ? decodeURIComponent(match[1]) : null, tab }
}

const go = (tripId: string | null, tab?: Tab) => { location.hash = tripId ? `#/trip/${encodeURIComponent(tripId)}${tab ? `/${tab}` : ''}` : '#/' }

/** On sign-out the phone must not keep the previous person's trips for offline use. */
function clearOfflineData() {
  try { navigator.serviceWorker?.controller?.postMessage('clear') } catch { /* no service worker */ }
}

export function App() {
  const [route, setRoute] = useState(parseHash)
  const [userName, setUserName] = useState('')
  const [trips, setTrips] = useState<TripSummary[] | null>(null)
  const [message, setMessage] = useState<{ text: string; error: boolean; action?: ToastAction } | null>(null)
  const timer = useRef<number>()

  const notify = useCallback((text: string, error = false, action?: ToastAction) => {
    setMessage({ text, error, action })
    window.clearTimeout(timer.current)
    timer.current = window.setTimeout(() => setMessage(null), error ? 8000 : action ? 9000 : 3500)
  }, [])

  const loadTrips = useCallback(async () => {
    try { setTrips(await api.trips()) } catch (error) { notify(messageOf(error), true) }
  }, [notify])

  useEffect(() => {
    const onHash = () => setRoute(parseHash())
    addEventListener('hashchange', onHash)
    api.me().then((me) => setUserName(me.name)).catch((e) => notify(messageOf(e), true))
    void loadTrips()
    return () => removeEventListener('hashchange', onHash)
  }, [])

  return (
    <Notify.Provider value={notify}>
      <div id="status" role="status" aria-live="polite" class={message ? `toast${message.error ? ' error' : ''}` : 'toast hidden'}>
        <span>{message?.text}</span>
        {message?.action && <button class="toast-action" onClick={() => { const run = message.action!.run; setMessage(null); run() }}>{message.action.label}</button>}
      </div>
      {trips === null ? <Skeleton lines={5} />
        : route.tripId ? <TripScreen key={route.tripId} tripId={route.tripId} tab={route.tab} userName={userName} trips={trips} onTripsChanged={loadTrips} />
        : (
          <>
            <TripList trips={trips} onOpen={(id) => go(id)} onChanged={async (openId) => { await loadTrips(); if (openId) go(openId) }} />
            <p class="note footer">Angemeldet als {userName} · <a href="/logout" onClick={clearOfflineData}>Abmelden</a></p>
          </>
        )}
    </Notify.Provider>
  )
}

function TripScreen(props: { tripId: string; tab: Tab | null; userName: string; trips: TripSummary[]; onTripsChanged: () => Promise<void> }) {
  const notify = useNotify()
  const [data, setData] = useState<TripData | null>(null)
  const [dialog, setDialog] = useState<'edit' | 'share' | 'export' | 'delete' | 'phase' | null>(null)
  const storageKey = `ideas-filter:${props.tripId}`
  const [filter, setFilter] = useState<IdeaFilter>(() => { try { return deserialize(localStorage.getItem(storageKey)) } catch { return deserialize(null) } })
  useEffect(() => { try { localStorage.setItem(storageKey, serialize(filter)) } catch { /* private mode */ } }, [filter])
  const revision = useRef(0)

  const load = useCallback(async () => {
    try {
      const next = await api.data(props.tripId)
      revision.current = next.revision
      setData(next)
    } catch (error) {
      notify(messageOf(error), true)
      go(null)
    }
  }, [props.tripId])

  useEffect(() => { void load() }, [load])

  // The server counts every change; asking for that one number every few seconds is enough to notice what Claude or the family did.
  useEffect(() => {
    const check = async () => {
      if (document.hidden) return
      try { const { revision: latest } = await api.revision(); if (latest !== revision.current) await load() } catch { /* offline: next time */ }
    }
    const interval = window.setInterval(check, 4000)
    document.addEventListener('visibilitychange', check)
    return () => { window.clearInterval(interval); document.removeEventListener('visibilitychange', check) }
  }, [load])

  // With nine tabs the bar scrolls sideways; keep the current one in view.
  useEffect(() => { document.querySelector('.tabs [aria-current="true"]')?.scrollIntoView({ inline: 'center', block: 'nearest' }) }, [props.tab, data !== null])

  if (!data) return <Skeleton lines={5} />
  const { trip } = data
  const canEdit = data.role !== 'viewer'
  const isOwner = data.role === 'owner'
  const view: ViewProps = { data, canEdit, reload: load }
  const tabs = TABS_FOR[trip.phase]
  const tab = props.tab && tabs.includes(props.tab) ? props.tab : tabs[0]
  const otherPhase: Phase = trip.phase === 'planning' ? 'building' : 'planning'
  const body = {
    ideas: <Ideas {...view} filter={filter} setFilter={setFilter} />, route: <Route {...view} />, timeline: <Timeline {...view} />, decisions: <Decisions {...view} />, plan: <Plan {...view} />,
    bookings: <Bookings {...view} />, budget: <Budget {...view} />, packing: <Packing {...view} />, log: <Log {...view} />,
  }[tab]

  return (
    <>
      <header class="header">
        <a class="back" href="#/">‹ Meine Reisen</a>
        <h1>{trip.name}</h1>
        <p>{[trip.destination, `${shortDate(trip.start_date)} bis ${shortDate(trip.end_date)} ${trip.end_date.slice(0, 4)}`].filter(Boolean).join(' · ')}</p>
        <p><span class={`badge phase ${trip.phase}`}>{PHASE_LABEL[trip.phase]}</span></p>
        <div class="actions">
          {canEdit && <button class={`btn ${trip.phase === 'planning' ? '' : 'secondary'}`} onClick={() => setDialog('phase')}>{trip.phase === 'planning' ? 'Aufbauphase starten' : 'Zurück zur Planung'}</button>}
          <Menu label="Mehr" items={[
            ...(canEdit ? [{ label: 'Reise bearbeiten', onSelect: () => setDialog('edit') }] : []),
            { label: `Teilen (${data.members.length})`, onSelect: () => setDialog('share') },
            { label: 'Exportieren …', onSelect: () => setDialog('export') },
            ...(isOwner ? [{ label: 'Reise löschen', onSelect: () => setDialog('delete'), danger: true }] : []),
          ]} />
        </div>
        {data.role === 'viewer' && <p class="note">Du kannst diese Reise nur ansehen.</p>}
      </header>
      <main class={tab === 'ideas' || tab === 'route' ? 'split' : ''}>{body}</main>
      <nav class="tabs" aria-label="Bereiche">
        {tabs.map((id) => <button aria-current={id === tab} onClick={() => { go(props.tripId, id); scrollTo(0, 0) }}><Icon name={id} size={22} /><span>{LABEL[id]}</span></button>)}
      </nav>
      {dialog === 'edit' && <TripForm trip={trip} onClose={() => setDialog(null)} onSaved={async () => { setDialog(null); await load(); await props.onTripsChanged() }} />}
      {dialog === 'phase' && <PhaseDialog trip={trip} to={otherPhase} onClose={() => setDialog(null)} onSaved={async () => { await load(); await props.onTripsChanged(); go(props.tripId) }} />}
      {dialog === 'share' && <ShareDialog trip={trip} members={data.members} isOwner={isOwner} onClose={() => setDialog(null)} onChanged={load} />}
      {dialog === 'export' && <ExportDialog trip={trip} onClose={() => setDialog(null)} />}
      {dialog === 'delete' && <DeleteDialog trip={trip} onClose={() => setDialog(null)} onDeleted={async () => { setDialog(null); await props.onTripsChanged(); go(null) }} />}
    </>
  )
}
