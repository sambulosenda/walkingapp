#!/usr/bin/env node
// Cuts a saved Overpass answer into street tiles, for filling the bucket ahead of launch.
//
//   node tools/cut.mjs <overpass.json> <out-dir> [--inside <lat>,<lon>,<radius-m>]
//
// With --inside, only tiles that lie wholly within that circle are written: a file fetched with an
// "around" query is only complete inside its circle, and a half-empty tile would be served for months.
// Then upload each file under the same path:  wrangler r2 object put unwalked-streets/v1/14/x/y.json --file ...

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { ZOOM, boundsOf, keyOf, pack, tileOf } from '../src/tiles.js'

const [source, out, flag, circle] = process.argv.slice(2)
if (!source || !out) {
  console.error('usage: cut.mjs <overpass.json> <out-dir> [--inside <lat>,<lon>,<radius-m>]')
  process.exit(1)
}
const { elements } = JSON.parse(readFileSync(source, 'utf8'))

const tiles = new Map()
for (const e of elements) {
  if (e.type !== 'node' || typeof e.lat !== 'number') continue
  const t = tileOf(e.lat, e.lon)
  tiles.set(`${t.x}/${t.y}`, t)
}

function metres(lat1, lon1, lat2, lon2) {
  const rad = Math.PI / 180
  const a = Math.sin(((lat2 - lat1) * rad) / 2) ** 2
    + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(((lon2 - lon1) * rad) / 2) ** 2
  return 2 * 6_371_000 * Math.asin(Math.sqrt(a))
}

let keep = () => true
if (flag === '--inside' && circle) {
  const [lat, lon, radius] = circle.split(',').map(Number)
  keep = (t) => {
    const b = boundsOf(t.x, t.y)
    return [[b.north, b.west], [b.north, b.east], [b.south, b.west], [b.south, b.east]]
      .every(([la, lo]) => metres(lat, lon, la, lo) <= radius)
  }
}

let written = 0
for (const t of tiles.values()) {
  if (!keep(t)) continue
  const file = join(out, keyOf(t.x, t.y))
  mkdirSync(dirname(file), { recursive: true })
  writeFileSync(file, JSON.stringify(pack(elements, { ...t, zoom: ZOOM })))
  written += 1
}
console.log(`${written} of ${tiles.size} tiles written to ${out}`)
