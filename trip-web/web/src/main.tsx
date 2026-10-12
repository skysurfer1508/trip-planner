import { render } from 'preact'
import './styles.css'
import { App } from './app'

render(<App />, document.getElementById('app')!)

// Offline reading: the service worker keeps what was opened. A failure here must never stop the site.
if ('serviceWorker' in navigator && location.protocol === 'https:' || location.hostname === 'localhost') {
  navigator.serviceWorker?.register('/sw.js').catch(() => {})
}
