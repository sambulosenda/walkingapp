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
so you can see turn cues, the Live Activity and Walk complete.

## What's where

| Folder | |
| --- | --- |
| `Unwalked/Screens` | The v2 screens: onboarding (location, pace, home area), Home (with First run and After dark), Loop options, Walking (with Off the loop, Running late and Report a street), Walk complete, Paywall, Settings |
| `Unwalked/Design` | Colours, type and shared components taken from the v2 designs |
| `Unwalked/Map` | The map and the layers drawn on it |
| `Unwalked/Services` | Location, loop planning, walk guidance, coverage, turn cues, StoreKit, Live Activity, watch link |
| `UnwalkedWidgets` | Lock Screen Live Activity and Dynamic Island |
| `UnwalkedWatch` | Watch app: turn screen, between-turns ring, wrist taps |
| `Shared` | Types used by more than one target |

## How it works

- **Loops** are planned with Apple's walking directions: home → two turning points → home, sized to the time
  you pick at your pace, in three directions. The one with the most new streets comes first.
- **New streets** are tracked on a ~20 m grid of everywhere you have walked. Coverage is walked cells over an
  estimate of street length in your home area (about 15 km of street per km²). Real street data from
  OpenStreetMap would make both exact.
- **Pace** starts from your onboarding pick and learns from your last five walks.
- **Guidance** follows you along the route: turn cues 20 to 30 m before each turn (two taps and a low tone for left,
  three taps and a high tone for right), a long buzz when you leave the loop, and a shortcut offer once you're
  running five minutes late.
- **Plus** is two StoreKit subscriptions, `com.unwalked.plus.yearly` and `com.unwalked.plus.monthly`.
  Two free loops a week, resetting on Monday.
- Everything is stored on the phone, in `Application Support/unwalked.json`.
