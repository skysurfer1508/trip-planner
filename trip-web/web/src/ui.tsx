import type { ComponentChildren } from 'preact'
import { createContext } from 'preact'
import { useContext, useEffect, useRef, useState } from 'preact/hooks'

/** A dialog on the browser's own <dialog>: focus stays inside, Escape closes it, and screen readers announce the title. */
export function Modal(props: { title: string; onClose: () => void; children: ComponentChildren }) {
  const ref = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    const dialog = ref.current!
    if (!dialog.open) dialog.showModal()
    return () => { if (dialog.open) dialog.close() }
  }, [])
  return (
    <dialog
      ref={ref}
      class="modal"
      aria-labelledby="modal-title"
      onClose={props.onClose}
      onClick={(event) => { if (event.target === ref.current) props.onClose() }}
    >
      <div class="modal-body">
        <h2 id="modal-title">{props.title}</h2>
        {props.children}
      </div>
    </dialog>
  )
}

export function Field(props: { label: string; hint?: string; children: ComponentChildren }) {
  return (
    <label class="field">
      <span class="field-label">{props.label}</span>
      {props.children}
      {props.hint && <span class="note">{props.hint}</span>}
    </label>
  )
}

/** One place to show "that did not work" and "done" without blocking pop-ups. */
export interface ToastAction { label: string; run: () => void }
export const Notify = createContext<(text: string, isError?: boolean, action?: ToastAction) => void>(() => {})
export const useNotify = () => useContext(Notify)

export function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** A small menu for the less common actions. It closes after a choice, on Escape and when you click elsewhere. */
export function Menu(props: { label: string; ariaLabel?: string; items: { label: string; onSelect: () => void; danger?: boolean }[] }) {
  const [open, setOpen] = useState(false)
  const root = useRef<HTMLDivElement>(null)
  const items = () => [...(root.current?.querySelectorAll<HTMLButtonElement>('[role="menuitem"]') ?? [])]
  useEffect(() => {
    if (!open) return
    items()[0]?.focus()
    const away = (event: Event) => { if (!root.current?.contains(event.target as Node)) setOpen(false) }
    const key = (event: KeyboardEvent) => {
      if (event.key === 'Escape') { setOpen(false); root.current?.querySelector<HTMLButtonElement>('[aria-haspopup]')?.focus(); return }
      const list = items()
      const at = list.indexOf(document.activeElement as HTMLButtonElement)
      if (event.key === 'ArrowDown') { event.preventDefault(); list[(at + 1) % list.length]?.focus() }
      if (event.key === 'ArrowUp') { event.preventDefault(); list[(at - 1 + list.length) % list.length]?.focus() }
      if (event.key === 'Home') { event.preventDefault(); list[0]?.focus() }
      if (event.key === 'End') { event.preventDefault(); list[list.length - 1]?.focus() }
    }
    document.addEventListener('pointerdown', away)
    document.addEventListener('keydown', key)
    return () => { document.removeEventListener('pointerdown', away); document.removeEventListener('keydown', key) }
  }, [open])
  return (
    <div class="menu" ref={root}>
      <button class="btn secondary" aria-label={props.ariaLabel} aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)}>{props.label} ▾</button>
      {open && (
        <div class="menu-items" role="menu">
          {props.items.map((item) => (
            <button role="menuitem" class={item.danger ? 'danger-text' : ''} onClick={() => { setOpen(false); item.onSelect() }}>{item.label}</button>
          ))}
        </div>
      )}
    </div>
  )
}

/** A grey placeholder while data loads, so the page does not jump when it arrives. */
export function Skeleton({ lines = 3 }: { lines?: number }) {
  return (
    <div class="skeleton" role="status" aria-label="Lädt">
      {Array.from({ length: lines }, (_, i) => <div class="skeleton-line" style={{ width: `${90 - i * 14}%` }} />)}
    </div>
  )
}
