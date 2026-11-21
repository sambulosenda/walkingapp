import { ZOOM, keyOf, queryFor, pack } from './tiles.js'
import { privacyPage } from './legal.js'

// Serves street tiles to the Unwalked app.
//
// A tile comes from the R2 bucket when it is there. When it is not, the Worker asks OpenStreetMap's
// Overpass service for that square, cuts the answer down, saves it and serves it, so every tile is
// only ever built once and the public Overpass servers see one request per square of map, not one per walker.

/** Tiles older than this are rebuilt on the next request; the old copy is served if that fails. */
const MAX_AGE_MS = 90 * 24 * 3600 * 1000
const HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  // Phones keep their own copy for 30 days; the edge may keep one for a day.
  'cache-control': 'public, max-age=86400',
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url)
    if (request.method !== 'GET') return new Response('Not found', { status: 404 })

    // The App Store listing and the paywall link here, so it has to stay up as long as the app is on sale.
    if (url.pathname === '/privacy' || url.pathname === '/privacy/') {
      return new Response(privacyPage(env.CONTACT_EMAIL ?? ''), {
        headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'public, max-age=3600' },
      })
    }

    const match = url.pathname.match(/^\/v2\/(\d+)\/(\d+)\/(\d+)\.json$/)
    if (!match) return new Response('Not found', { status: 404 })
    const [zoom, x, y] = match.slice(1).map(Number)
    const size = 2 ** ZOOM
    if (zoom !== ZOOM || x >= size || y >= size) return new Response('Not found', { status: 404 })

    const cache = caches.default
    const cacheKey = new Request(url.origin + url.pathname)
    const cached = await cache.match(cacheKey)
    if (cached) return cached

    const key = keyOf(x, y)
    const saved = await env.TILES.get(key)
    if (saved && Date.now() - saved.uploaded.getTime() < MAX_AGE_MS) {
      return respond(await saved.text(), cache, cacheKey, ctx)
    }

    // Building a tile costs a third party a query, so one address may only ask for so many a minute.
    const who = request.headers.get('cf-connecting-ip') ?? 'unknown'
    const allowed = env.FILL_LIMITER ? (await env.FILL_LIMITER.limit({ key: who })).success : true
    const fresh = allowed ? await build(x, y, env) : null
    if (fresh) {
      ctx.waitUntil(env.TILES.put(key, fresh, { httpMetadata: { contentType: HEADERS['content-type'] } }))
      return respond(fresh, cache, cacheKey, ctx)
    }
    if (saved) return new Response(await saved.text(), { headers: HEADERS })
    return new Response('Tile not ready', { status: allowed ? 503 : 429, headers: { 'retry-after': '30' } })
  },
}

function respond(body, cache, cacheKey, ctx) {
  const response = new Response(body, { headers: HEADERS })
  ctx.waitUntil(cache.put(cacheKey, response.clone()))
  return response
}

/** Asks each Overpass server in turn for the streets in a tile. Null when none answers. */
async function build(x, y, env) {
  const endpoints = (env.OVERPASS_ENDPOINTS ?? '').split(',').map((s) => s.trim()).filter(Boolean)
  const body = 'data=' + encodeURIComponent(queryFor(x, y))
  for (const endpoint of endpoints) {
    try {
      const response = await fetch(endpoint, {
        method: 'POST',
        body,
        headers: { 'content-type': 'application/x-www-form-urlencoded', 'user-agent': 'Unwalked-tiles/1' },
        signal: AbortSignal.timeout(28_000),
      })
      if (!response.ok) {
        console.log('overpass refused', endpoint, response.status)
        continue
      }
      const data = await response.json()
      // Overpass answers 200 with a remark and no data when it runs out of time.
      if (!Array.isArray(data.elements) || data.remark) {
        console.log('overpass had no data', endpoint, data.remark ?? 'no elements')
        continue
      }
      return JSON.stringify(pack(data.elements))
    } catch (error) {
      console.log('overpass failed', endpoint, String(error))
      continue
    }
  }
  return null
}
