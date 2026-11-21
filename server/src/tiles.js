// Street tiles: the walkable-street data for one square of the map, cut down to what the app reads.
// Shared by the Worker and the seeding tool.

export const ZOOM = 14

/** Tags the app's street rules read. Everything else is dropped. */
const KEEP = [
  'highway', 'name', 'ref', 'foot', 'access', 'area', 'service', 'maxspeed', 'junction', 'oneway',
  'sidewalk', 'sidewalk:both', 'sidewalk:left', 'sidewalk:right', 'lit',
]

/** Parks, gardens, commons and woods: a way that runs through one is marked `green`. */
const GREEN = [
  'way["leisure"~"^(park|garden|nature_reserve|common)$"]',
  'relation["leisure"~"^(park|garden|nature_reserve|common)$"]',
  'way["landuse"~"^(forest|meadow|grass|recreation_ground|village_green)$"]',
  'way["natural"~"^(wood|heath|grassland|scrub)$"]',
]

export function tileOf(lat, lon, zoom = ZOOM) {
  const n = 2 ** zoom
  const rad = (lat * Math.PI) / 180
  const x = Math.floor(((lon + 180) / 360) * n)
  const y = Math.floor(((1 - Math.asinh(Math.tan(rad)) / Math.PI) / 2) * n)
  return { x: Math.min(n - 1, Math.max(0, x)), y: Math.min(n - 1, Math.max(0, y)) }
}

/** South, west, north and east edges of a tile, in degrees. */
export function boundsOf(x, y, zoom = ZOOM) {
  const n = 2 ** zoom
  const lat = (row) => (Math.atan(Math.sinh(Math.PI * (1 - (2 * row) / n))) * 180) / Math.PI
  return { south: lat(y + 1), west: (x / n) * 360 - 180, north: lat(y), east: ((x + 1) / n) * 360 - 180 }
}

export function keyOf(x, y, zoom = ZOOM) {
  return `v3/${zoom}/${x}/${y}.json`
}

/** The Overpass query for every street with a point inside a tile. */
export function queryFor(x, y, zoom = ZOOM) {
  const b = boundsOf(x, y, zoom)
  const box = [b.south, b.west, b.north, b.east].map((v) => v.toFixed(6)).join(',')
  // The streets in full, then the ids alone of those that run through green space. Overpass works
  // out which are inside a park, so no park outline has to reach the phone.
  const green = GREEN.map((g) => `${g}(${box});`).join('')
  return `[out:json][timeout:25];way["highway"](${box});out body;>;out skel qt;` +
    `(${green});map_to_area->.g;way["highway"](area.g)(${box});out ids;`
}

/**
 * Packs Overpass elements into a tile: the streets, the points they use, and only the tags the app reads.
 * With `tile`, keeps only the streets that have a point inside it.
 *
 * Points are three matching lists (`ids`, `lat`, `lon`) and each street's `nodes` are positions in those
 * lists, which is about a third of the size of Overpass's own JSON and much quicker for a phone to read.
 * `ids` are OpenStreetMap's, so a street that crosses into the next tile joins up with itself there.
 */
export function pack(elements, tile) {
  const coords = new Map()
  for (const e of elements) {
    if (e.type === 'node' && typeof e.lat === 'number') coords.set(e.id, e)
  }
  const inside = tile
    ? (id) => {
        const c = coords.get(id)
        if (!c) return false
        const t = tileOf(c.lat, c.lon, tile.zoom ?? ZOOM)
        return t.x === tile.x && t.y === tile.y
      }
    : null

  const ids = []
  const lat = []
  const lon = []
  const position = new Map()
  const place = (id) => {
    let i = position.get(id)
    if (i === undefined) {
      const c = coords.get(id)
      i = ids.length
      position.set(id, i)
      ids.push(id)
      // Seven decimal places is about a centimetre: all OpenStreetMap stores.
      lat.push(+c.lat.toFixed(7))
      lon.push(+c.lon.toFixed(7))
    }
    return i
  }

  // Ways that arrive as an id alone are the ones Overpass found inside green space.
  const green = new Set()
  for (const e of elements) {
    if (e.type === 'way' && !Array.isArray(e.nodes)) green.add(e.id)
  }

  const ways = []
  const seen = new Set()
  for (const e of elements) {
    if (e.type !== 'way' || !e.tags?.highway || !Array.isArray(e.nodes)) continue
    if (seen.has(e.id)) continue
    const known = e.nodes.filter((id) => coords.has(id))
    if (known.length < 2) continue
    if (inside && !known.some(inside)) continue
    seen.add(e.id)
    const tags = {}
    for (const k of KEEP) if (e.tags[k] !== undefined) tags[k] = e.tags[k]
    if (green.has(e.id)) tags.green = 'yes'
    ways.push({ id: e.id, nodes: known.map(place), tags })
  }
  return { ids, lat, lon, ways }
}
