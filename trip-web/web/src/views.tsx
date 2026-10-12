import { useState } from 'preact/hooks'
import { api } from './api'
import { ago } from './format'
import { DecisionDialog } from './edit'
import type { Decision, TripData } from './types'
import { messageOf, useNotify } from './ui'

export interface ViewProps {
  data: TripData
  canEdit: boolean
  reload: () => Promise<void>
  /** Shows a change on screen at once; the server call follows and `reload` puts things right if it fails. */
  mutate: (change: (data: TripData) => TripData) => void
}

// MARK: Read-only lists (editing follows in the next steps)

export function Decisions({ data, canEdit, reload }: ViewProps) {
  const notify = useNotify()
  const [editing, setEditing] = useState<Decision | 'new' | null>(null)
  const move = async (d: Decision) => {
    try { await api.patch('decision', d.id, { kind: d.kind === 'open' ? 'decided' : 'open' }); await reload() } catch (error) { notify(messageOf(error), true) }
  }
  const section = (kind: 'decided' | 'open', title: string, empty: string) => {
    const items = data.decisions.filter((x) => x.kind === kind)
    return (
      <>
        <h2>{title}</h2>
        <div class="card">
          {items.length === 0 && <p class="empty">{empty}</p>}
          {items.map((x) => (
            <div class="row">
              <div class="body"><div class="title">{x.title}</div><div class="meta">{x.detail}</div></div>
              {canEdit && (
                <div class="place-actions">
                  <button type="button" class="btn quiet" onClick={() => move(x)}>{kind === 'open' ? 'Ist entschieden' : 'Wieder öffnen'}</button>
                  <button type="button" class="btn quiet" onClick={() => setEditing(x)}>Bearbeiten</button>
                </div>
              )}
            </div>
          ))}
        </div>
      </>
    )
  }
  return (
    <>
      {canEdit && <div class="actions"><button class="btn" onClick={() => setEditing('new')}>Entscheid oder Frage hinzufügen</button></div>}
      {section('open', 'Noch offen', 'Nichts offen.')}
      {section('decided', 'Entschieden', 'Noch nichts entschieden.')}
      {editing && <DecisionDialog tripId={data.trip.id} decision={editing === 'new' ? undefined : editing} onClose={() => setEditing(null)} onSaved={reload} />}
    </>
  )
}

const VIA: Record<string, string> = { web: 'Website', claude: 'Claude', import: 'Import', app: 'App' }

export function Log({ data, canEdit, reload }: ViewProps) {
  const notify = useNotify()
  if (data.log.length === 0) return <p class="empty">Noch keine Änderungen.</p>
  const undo = async (id: string) => {
    try { await api.undo(id); await reload() } catch (error) { notify(messageOf(error), true) }
  }
  return (
    <div class="card">
      {data.log.map((entry) => (
        <div class="row">
          <div class="body">
            <div class="title">{entry.summary || 'Änderung'}{entry.undone_at ? ' (rückgängig)' : ''}</div>
            <div class="meta"><span class={`badge${entry.via === 'claude' ? ' claude' : ''}`}>{VIA[entry.via]}</span> {entry.actor ? `${entry.actor} · ` : ''}{ago(entry.created_at)}</div>
          </div>
          {canEdit && !entry.undone_at && !entry.summary.startsWith('Rückgängig') && entry.via !== 'import' && entry.via !== 'app' && !entry.summary.startsWith('Reise ') && <button class="btn quiet" onClick={() => undo(entry.id)}>Rückgängig</button>}
        </div>
      ))}
    </div>
  )
}
