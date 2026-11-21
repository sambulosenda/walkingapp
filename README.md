# Unwalked

Walking loops from your door that take you down streets you haven't walked yet.
Native iOS app in SwiftUI, with a Live Activity, Dynamic Island and an Apple Watch companion.

## Run it

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen), so it never conflicts in git.

```sh
brew install xcodegen
xcodegen
open Unwalked.xcodeproj
```

Pick your team under Signing for the three targets, then run the **Unwalked** scheme.

Requires Xcode 16+, iOS 17+, watchOS 10+.

### Trying a walk without leaving your desk

In the Simulator, set a location (Features › Location › Custom Location), plan a loop, and launch with the
`-simulateWalk` argument (Scheme › Run › Arguments). The walker then moves round the loop at 5x speed,
so you can see turn cues, the Live Activity and Walk complete. Add `-plus` to try the Plus features
without a purchase.

## What's where

| Folder | |
| --- | --- |
| `Unwalked/Screens` | The v2 screens: onboarding (location, pace, home area), Home (with First run and After dark), Loop options, Walking (with Off the loop, Running late and Report a street), Walk complete, Paywall, Settings |
| `Unwalked/Design` | Colours, type and shared components taken from the v2 designs |
| `Unwalked/Map` | The map and the layers drawn on it |
| `Unwalked/Services/Streets` | OpenStreetMap download, street graph and the loop engine |
| `Unwalked/Services` | Location, loop planning, walk guidance, coverage, turn cues, StoreKit, Live Activity, watch link |
| `UnwalkedWidgets` | Lock Screen Live Activity and Dynamic Island |
| `UnwalkedWatch` | Watch app: turn screen, between-turns ring, wrist taps |
| `Shared` | Types used by more than one target |
| `UnwalkedUITests` | Walks through every main screen running Apple's accessibility audit |
| `server` | Cloudflare Worker that serves street tiles from an R2 bucket, and the privacy policy at `/privacy` |
| `Tools` | `MakeAppIcon.swift`, which draws the app icon |

## How it works

- **Streets** come from OpenStreetMap: the walkable ways around your home area are downloaded once, kept on the
  phone and refreshed monthly. They arrive as map tiles (zoom 14, about 1.5 km across) from the tile server in
  `server/`, and from the public Overpass API when no server is set or it has no answer. Private ways, driveways
  and anything closed to walkers are left out; main roads without a pavement cost extra.
- **Loops** are planned on the phone, on that street graph: 24 candidate loops in different directions, each resized
  to the time you pick at your pace, scored for new streets, main roads and doubling back. The best three are shown,
  most new first. Until the streets have downloaded, loops fall back to Apple's walking directions.
- **New streets**: a stretch of street counts as walked once 90% of it is covered. Coverage is walked street length
  over all street length in your home area. Walks are stored as a ~20 m grid, so the map survives street data changing.
- **Pace** starts from your onboarding pick and learns from your last five walks.
- **Guidance** follows you along the route: turn cues 20 to 30 m before each turn (two taps and a low tone for left,
  three taps and a high tone for right, then the turn spoken), a new route when you leave the loop by 30 m, and a
  shortcut offer once you would be more than 10% over your time.
- **Route preferences**: quiet, green, well lit and step-free are chips on Loop options. Green uses a
  mark the street data carries for ways that run through a park, garden, common or wood; step-free
  never uses a flight of steps. Quiet, green and step-free are part of Plus.
- **Part-way round**, tapping the time left makes the walk ten minutes shorter or longer (Plus).
- **A stop on the way**: Apple's search finds a café, post box or shop, and every loop goes out through it.
- **Apple Health**: past walking routes can be brought in to colour the map (Plus), and each walk can be
  saved as a workout. Needs the HealthKit capability on the App ID.
- **Sharing** a walk or the map makes a picture of the streets alone. The streets round home are left off, as a patch of random size
  set off to one side, so its middle is not the door.
- **Plus** is two StoreKit subscriptions, `com.unwalked.plus.yearly` and `com.unwalked.plus.monthly`.
  Two free loops a week, resetting on Monday.
- Everything is stored on the phone, in `Application Support/unwalked.json`. Test purchases with `Unwalked.storekit`,
  which the Run scheme already uses.

## Street tile server

The public Overpass servers take 25 to 55 seconds for a neighbourhood and turn automated traffic away when busy,
so the app should not depend on them. `server/` is a Cloudflare Worker in front of an R2 bucket:

- `GET /v3/14/{x}/{y}.json` returns the streets in one tile, already cut down to the tags the app reads.
- A tile that is in the bucket is served from it. One that is not is fetched from Overpass once, saved and served,
  so each square of the map is only ever built one time. One address may trigger 40 builds a minute.
- `node server/tools/cut.mjs <overpass.json> <out-dir> --inside <lat>,<lon>,<radius>` cuts a saved Overpass answer
  into tiles, for filling the bucket ahead of launch.

```sh
cd server
wrangler dev                              # run it on this Mac, http://localhost:8787
wrangler r2 bucket create unwalked-streets
wrangler deploy
```

Then put the Worker's address in `StreetTilesURL` in `project.yml` and run `xcodegen`. To try a local server from
the Simulator, launch the app with `-streetTilesURL http://localhost:8787`.

## Before a build goes out

- **`PrivacyPolicyURL`** in `project.yml` has to point at a live page, or App Review turns the
  subscription paywall down. The Worker serves one at `/privacy`; set `CONTACT_EMAIL` in
  `server/wrangler.toml` first so the page has a way to reach a human.
- **Deploy the Worker** before shipping a build that sets `StreetTilesURL`.
- The app icon is drawn by a script, so it can be changed in one place and regenerated:

```sh
swift Tools/MakeAppIcon.swift Unwalked/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```

It writes a 1024×1024 PNG with no alpha channel, which is what the App Store accepts.

- `PrivacyInfo.xcprivacy` in each of the three targets declares what leaves the phone (coarse
  map-tile requests, nothing else) and why the app reads `UserDefaults` and a file's modification
  date. Keep it in step with the answers given in App Store Connect.

## Accessibility

Text follows the reader's text size setting up to the largest accessibility size; sheets scroll when they outgrow
the screen and the controls over the map stay reachable. Reduce Motion, Reduce Transparency and Increase Contrast
are honoured. The audit runs with:

```sh
xcodebuild test -project Unwalked.xcodeproj -scheme Unwalked -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
# the same walk-through at the largest text size
TEST_RUNNER_TEXT_SIZE=AccessibilityXXXL xcodebuild test ...
```

It needs an onboarded app with a home area, and street data (or a network connection) to plan a loop.

