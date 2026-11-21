// The privacy policy the App Store listing and the paywall both link to.
//
// It lives here because the Worker is already the app's only backend, so there is no
// second thing to deploy or keep alive. Apple requires this page to stay reachable for
// as long as the app is on sale.

const UPDATED = '21 November 2026'

const STYLE = `
  :root { color-scheme: light dark; --ink: #14262B; --ground: #F1F2EE; --muted: #56666A; }
  @media (prefers-color-scheme: dark) {
    :root { --ink: #F2F5F6; --ground: #0E1517; --muted: #9FB0B5; }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 48px 20px 96px; background: var(--ground); color: var(--ink);
    font: 17px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  }
  main { max-width: 34rem; margin: 0 auto; }
  h1 { font-size: 2rem; line-height: 1.2; margin: 0 0 .25rem; letter-spacing: -0.02em; }
  h2 { font-size: 1.15rem; margin: 2.25rem 0 .5rem; letter-spacing: -0.01em; }
  p, li { margin: 0 0 .85rem; }
  ul { padding-left: 1.2rem; }
  .updated { color: var(--muted); margin-bottom: 2rem; }
  a { color: inherit; }
`

function page(title, body) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} · Unwalked</title>
<style>${STYLE}</style>
</head>
<body><main>${body}</main></body>
</html>`
}

export function privacyPage(contact) {
  const reach = contact
    ? `<p>Questions about any of this: <a href="mailto:${contact}">${contact}</a>.</p>`
    : ''

  return page(
    'Privacy',
    `
<h1>Privacy</h1>
<p class="updated">Unwalked · last updated ${UPDATED}</p>

<p>Unwalked keeps your walks on your phone. There is no account, no sign-in, and no server
that holds anything about you.</p>

<h2>What stays on your phone</h2>
<p>Your home area, the streets you have walked, your coverage, your pace and your settings are
written to a single file inside the app and never leave the device. Deleting the app deletes
all of it. Nobody, including us, can recover it.</p>

<h2>What leaves your phone</h2>
<ul>
  <li><strong>Street data.</strong> To plan loops, the app downloads the walkable streets around
  your home area as map squares about 1.5 km across. It asks our tile server, and the public
  OpenStreetMap Overpass service when ours has no answer. Those requests say which square of the
  map is wanted — not where you are, and not who you are. No identifier of any kind is attached.</li>
  <li><strong>Before the streets arrive.</strong> The first loop you plan may fall back to Apple's
  walking directions, which sends start and end points to Apple under
  <a href="https://www.apple.com/legal/privacy/">Apple's privacy policy</a>.</li>
  <li><strong>A street you report.</strong> If you tell Unwalked a street is blocked, private or
  feels unsafe, it sends the street's name, the map square it sits in, how long the stretch was,
  the reason and the date, so the street can be checked. It does not send where you were, what
  time it was, or anything that identifies you or your phone.</li>
  <li><strong>A stop you search for.</strong> If you ask a loop to pass a café, a post box or a shop,
  the search is Apple's: what you typed and the area searched go to Apple under
  <a href="https://www.apple.com/legal/privacy/">Apple's privacy policy</a>, and not to us.</li>
  <li><strong>Server logs.</strong> Our tile server runs on Cloudflare, which records the IP address
  of incoming requests for a short time to keep the service up and stop abuse. We do not join those
  logs to anything else, and we do not try to identify anyone from them.</li>
</ul>

<h2>Location</h2>
<p>Unwalked asks for your location so it can guide you along a loop and fill in your map as you
walk. It is used on the phone, as you walk, and written only to that file on your phone. You can
turn it off at any time in iOS Settings; the app cannot guide a walk without it.</p>

<h2>Apple Health</h2>
<p>Only if you ask it to, Unwalked reads the routes of walking and hiking workouts from Apple Health
to colour in streets you have already walked, and can save each of your walks to Health as a workout.
What it reads stays on your phone with your other walks. Nothing from Apple Health is sent to us or
to anyone else, and it is never used for advertising.</p>

<h2>Unwalked Plus</h2>
<p>Subscriptions are sold and renewed by Apple. Apple tells the app whether a subscription is
active. We never see your name, your payment details or your Apple Account.</p>

<h2>What we do not do</h2>
<p>No analytics, no advertising, no trackers, no third-party SDKs, no profiles, no data sold or
shared. Unwalked does not track you across apps or websites.</p>

<h2>Children</h2>
<p>Unwalked is not aimed at children under 13 and collects nothing that would identify anyone,
of any age.</p>

<h2>Changes</h2>
<p>If this policy changes, the date at the top changes with it.</p>
${reach}
`
  )
}
