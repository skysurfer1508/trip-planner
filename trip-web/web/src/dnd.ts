/** Drag and drop with pointer events, so it works with a mouse, a finger and a pen. Only the grip starts a drag, the rest of the row keeps scrolling.
 *
 * Markup contract: every draggable row has `data-drag-item="<id>"`, `data-drag-group="<group>"` and `data-drag-index="<position in its group>"`;
 * the box around the rows of a group has `data-drag-container="<group>"` (it takes drops into an empty group or at the end).
 * `onDrop` gets the dragged id and where it was dropped: the group and the position it would be inserted *before* (the group's length = at the end).
 */
export interface DropTarget { id: string; fromGroup: string; fromIndex: number; group: string; before: number }

const MARK = ['drag-before', 'drag-after', 'drag-into']

/** Where an item dragged from `from` ends up in a list when it is dropped before position `before` (positions count the item itself). */
export function finalIndex(fromGroup: string, fromIndex: number, group: string, before: number): number {
  return fromGroup === group && before > fromIndex ? before - 1 : before
}

function clear() {
  for (const name of MARK) document.querySelectorAll(`.${name}`).forEach((el) => el.classList.remove(name))
}

function locate(x: number, y: number): { group: string; before: number; mark: Element; cls: string } | null {
  const under = document.elementFromPoint(x, y)
  const row = under?.closest<HTMLElement>('[data-drag-item]')
  if (row) {
    const rect = row.getBoundingClientRect()
    const after = y > rect.top + rect.height / 2
    const index = Number(row.dataset.dragIndex)
    return { group: row.dataset.dragGroup!, before: index + (after ? 1 : 0), mark: row, cls: after ? 'drag-after' : 'drag-before' }
  }
  const box = under?.closest<HTMLElement>('[data-drag-container]')
  if (box) {
    const count = box.querySelectorAll('[data-drag-item]').length
    return { group: box.dataset.dragContainer!, before: count, mark: box, cls: 'drag-into' }
  }
  return null
}

export function startDrag(event: PointerEvent, onDrop: (drop: DropTarget) => void): void {
  const row = (event.currentTarget as HTMLElement).closest<HTMLElement>('[data-drag-item]')
  if (!row || (event.pointerType === 'mouse' && event.button !== 0)) return
  event.preventDefault()
  const from = { id: row.dataset.dragItem!, group: row.dataset.dragGroup!, index: Number(row.dataset.dragIndex) }
  let target: ReturnType<typeof locate> = null
  row.classList.add('dragging')
  document.body.classList.add('is-dragging')

  const move = (e: PointerEvent) => {
    clear()
    target = locate(e.clientX, e.clientY)
    target?.mark.classList.add(target.cls)
    // Scroll near the edges so a long day can be reached while dragging.
    if (e.clientY < 80) window.scrollBy(0, -14)
    else if (e.clientY > window.innerHeight - 140) window.scrollBy(0, 14)
  }
  const finish = (drop: boolean) => {
    document.removeEventListener('pointermove', move)
    document.removeEventListener('pointerup', up)
    document.removeEventListener('pointercancel', cancel)
    document.removeEventListener('keydown', key)
    row.classList.remove('dragging')
    document.body.classList.remove('is-dragging')
    clear()
    if (drop && target) onDrop({ id: from.id, fromGroup: from.group, fromIndex: from.index, group: target.group, before: target.before })
  }
  const up = () => finish(true)
  const cancel = () => finish(false)
  const key = (e: KeyboardEvent) => { if (e.key === 'Escape') finish(false) }
  document.addEventListener('pointermove', move)
  document.addEventListener('pointerup', up)
  document.addEventListener('pointercancel', cancel)
  document.addEventListener('keydown', key)
}
