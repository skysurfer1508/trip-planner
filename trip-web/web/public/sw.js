/* Offline reading. Pages and data the person has opened are kept; changes still need a connection (iPhones cannot sync in the background).
 * - the app files (hashed, never change) and the page shell: from the cache first
 * - trip data (GET /api/...): from the network, the cache when offline
 * - map tiles: from the cache first, at most a few thousand
 * Everything else (login, logout, changing calls) always goes to the network. */
const VERSION = 'v1'
const SHELL = `shell-${VERSION}`
const DATA = `data-${VERSION}`
const TILES = `tiles-${VERSION}`
const MAX_TILES = 1500

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(SHELL).then((cache) => cache.addAll(['/manifest.webmanifest', '/icon-192.png'])).then(() => self.skipWaiting()))
})

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) if (![SHELL, DATA, TILES].includes(name)) await caches.delete(name)
    await self.clients.claim()
  })())
})

self.addEventListener('message', (event) => {
  // Sent on sign-out: what was kept belongs to the person who just left.
  if (event.data === 'clear') event.waitUntil(Promise.all([caches.delete(DATA), caches.delete(SHELL), caches.delete(TILES)]))
})

async function trimTiles(cache) {
  const keys = await cache.keys()
  for (const key of keys.slice(0, Math.max(0, keys.length - MAX_TILES))) await cache.delete(key)
}

self.addEventListener('fetch', (event) => {
  const request = event.request
  if (request.method !== 'GET') return
  const url = new URL(request.url)

  if (url.hostname === 'tile.openstreetmap.org') {
    event.respondWith((async () => {
      const cache = await caches.open(TILES)
      const hit = await cache.match(request)
      if (hit) return hit
      try {
        const response = await fetch(request)
        if (response.ok) { await cache.put(request, response.clone()); trimTiles(cache) }
        return response
      } catch { return new Response('', { status: 504 }) }
    })())
    return
  }
  if (url.origin !== location.origin) return

  if (url.pathname.startsWith('/assets/')) {
    event.respondWith((async () => {
      const cache = await caches.open(SHELL)
      const hit = await cache.match(request)
      if (hit) return hit
      const response = await fetch(request)
      if (response.ok) await cache.put(request, response.clone())
      return response
    })())
    return
  }

  if (request.mode === 'navigate' && (url.pathname === '/' || url.pathname === '/index.html')) {
    event.respondWith((async () => {
      const cache = await caches.open(SHELL)
      try {
        const response = await fetch(request)
        if (response.ok && !response.redirected) await cache.put('/', response.clone())
        return response
      } catch {
        return (await cache.match('/')) || new Response('Offline', { status: 503 })
      }
    })())
    return
  }

  if (url.pathname.startsWith('/api/') && !url.pathname.startsWith('/api/revision') && !url.pathname.includes('/export') && !url.pathname.includes('/path') && !url.pathname.startsWith('/api/search')) {
    event.respondWith((async () => {
      const cache = await caches.open(DATA)
      try {
        const response = await fetch(request)
        if (response.ok) await cache.put(request, response.clone())
        return response
      } catch {
        return (await cache.match(request)) || new Response(JSON.stringify({ detail: 'Offline' }), { status: 503, headers: { 'Content-Type': 'application/json' } })
      }
    })())
  }
})
