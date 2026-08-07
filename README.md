# Heads Up

A native macOS menu-bar app that watches your Google Calendar and puts a
full-screen alert in front of you before each meeting starts. This is a
native Swift rewrite of the original Electron/TypeScript "Heads Up" (built
with Glaze); the original source is preserved in `GLAZE ORIGINAL/` for
reference and is not built or run any more.

The app lives entirely in the menu bar (`LSUIElement`, no Dock icon). It
shows the next or current meeting's countdown/status in the tray, opens a
calendar list window on click, and fires a full-screen "you're up" alert a
configurable number of minutes before each meeting.

## What it does

- Signs in to one or more Google accounts via OAuth (Desktop app flow, loopback
  redirect, no browser extension or embedded webview).
- Polls Google Calendar (read-only) across all enabled calendars per account.
- Shows the next/ongoing meeting in the menu-bar item, with an icon state for
  "nothing soon", "upcoming", "ongoing", and "tomorrow".
- Fires a full-screen alert window at one or two configurable lead times
  before a meeting starts, with a snooze option.
- A calendar list window (click the tray icon) shows the day-by-day upcoming
  meetings, bucketed and labelled.
- A Settings window handles Google credentials, per-calendar enable/disable,
  lead-time configuration, and appearance.

## Quick start

```bash
git clone https://github.com/yoavcaspi1/heads-up.git
cd heads-up
swift run HeadsUpChecks   # optional: run the test suite, expect "passed 73, failed 0"
./build_app.sh release    # builds, signs and installs /Applications/Heads Up.app
```

Two one-time setup steps are needed before the app is fully working:

1. A self-signed code-signing certificate named `HeadsUp Developer`
   (`build_app.sh` refuses ad-hoc signing) — see
   [One-time code-signing certificate](#one-time-code-signing-certificate).
2. Your own Google OAuth client ID and secret, pasted into the app's
   Settings — see [Google OAuth setup](#google-oauth-setup-one-time-per-google-cloud-project).

## Requirements

- macOS 14.0 (Sonoma) or later.
- Swift 5.10+ / Xcode Command Line Tools. A full Xcode install is not
  required to build from the command line, but Xcode can also open the
  package directly (`File > Open` on the folder, or `open Package.swift`) for
  GUI debugging.
- No third-party Swift packages. Zero SPM dependencies.

## Building

### Command line (SPM)

```bash
swift build                # debug build, compiles the HeadsUp executable target
swift build -c release     # release build
swift run HeadsUpChecks    # runs the full check suite (see "Tests" below)
```

`swift build` alone produces a bare executable, not a double-clickable
`.app`. For a real app bundle, use `build_app.sh` (below).

### Xcode GUI

Open the folder in Xcode (`open Package.swift` or drag the folder onto
Xcode). Xcode resolves the SPM package automatically, exposes the `HeadsUp`
and `HeadsUpChecks` schemes, and can build/run/debug either target
interactively. `HeadsUpKit` (the shared library target) is not directly
runnable; it is exercised through the other two.

### `build_app.sh` (proper `.app` bundle)

```bash
./build_app.sh                 # debug build, installs to /Applications and relaunches
./build_app.sh release          # optimized release build
./build_app.sh --no-install     # build and sign only, skip install/relaunch
./build_app.sh --force          # skip waiting for a running instance to quit first
```

This wraps `swift build`, assembles `build/Heads Up.app` (Info.plist,
bundled fonts, app icon), code-signs it, and by default installs it to
`/Applications/Heads Up.app` and relaunches it. `--no-install` is the safe
option when you just want a signed bundle without touching a running
instance (for example, while a recording or call is in progress on this
machine — never quit/relaunch the app mid-call).

**Do not run `build_app.sh` without `--no-install` while the app is actively
being used for something time-sensitive** (an armed alert about to fire, a
call in progress on the same machine). It force-quits any running instance
before installing.

#### One-time code-signing certificate

`build_app.sh` refuses to run with ad-hoc signing, because ad-hoc signatures
change on every build and macOS treats that as a "new app," resetting all TCC
permission grants (Notifications, etc.) each time. It signs with a stable
self-signed identity named `HeadsUp Developer` instead, which must be created
once per machine:

1. Open **Keychain Access**.
2. Menu bar: **Keychain Access > Certificate Assistant > Create a Certificate…**
3. Name: `HeadsUp Developer`
4. Identity Type: **Self Signed Root**
5. Certificate Type: **Code Signing**
6. Leave the rest at defaults and click **Create**.

Verify it is visible to `codesign`:

```bash
security find-identity -v -p codesigning
```

Self-signed identities sometimes show up as "invalid" in that listing even
though `codesign` accepts them fine; `build_app.sh` checks this itself by
attempting a real test-sign, not by parsing that output, so trust the script's
own error message over the raw `security find-identity` listing.

## Google OAuth setup (one-time, per Google Cloud project)

Heads Up authenticates against Google Calendar using your own OAuth client
credentials, entered in the app's Settings window; there is no shared/bundled
client ID.

1. Go to the [Google Cloud console](https://console.cloud.google.com/).
2. Create a project (or reuse an existing one).
3. **APIs & Services > Library**: search for **Google Calendar API** and
   enable it.
4. **APIs & Services > Credentials > Create credentials > OAuth client ID**.
5. Application type: **Desktop app**. Give it any name.
6. Save the generated **Client ID** and **Client secret**.
7. If prompted to configure the OAuth consent screen first, do so (External
   or Internal depending on the Google Workspace setup; scopes requested are
   `calendar.readonly`, `openid`, `email`, `profile`).
8. In Heads Up, open **Settings > Google connection**, paste the Client ID
   and Client secret, and click **Save credentials**.
9. Click **Add account** (or equivalent) to run the OAuth flow. Heads Up
   opens your default browser to Google's consent screen and starts a
   one-shot, loopback-only HTTP listener on `127.0.0.1` (an ephemeral port,
   PKCE-protected) to receive the redirect. No fixed redirect URI needs to be
   registered in the Cloud console for a Desktop app client; Google allows
   any loopback port for this client type.

Repeat step 9 for each Google account you want alerts from; the client
ID/secret from steps 2-6 is shared across all accounts added this way.

## Updates

The app updates itself from this repository. Every few hours (and shortly
after each launch) it compares its own version against the `VERSION` file on
`main`; when a newer version is published, the tray icon's right-click menu
grows an **Update to X.Y.Z…** item. Clicking it (and confirming) pulls the
latest code into the checkout the app was built from, rebuilds, reinstalls
to `/Applications`, and relaunches — all automatic, with progress written to
`~/Library/Logs/HeadsUp-update.log`.

For this to work, keep the cloned folder around after installing; the build
records its location inside the app bundle. If the folder has been moved or
deleted, the update item opens this repository page instead, and you can
re-clone and rebuild manually:

```bash
git pull
./build_app.sh release
```

## Where data lives

- **Settings and account list**: JSON files in
  `~/Library/Application Support/HeadsUp/`
  - `settings.json` — lead times, enabled calendars, appearance, etc.
  - `accounts.json` — the list of connected Google accounts and their
    per-account state (reconnect-needed flags, etc.). Tokens themselves are
    not in this file.
- **OAuth client secret and per-account tokens**: macOS Keychain, service
  name `com.cedoreholdings.headsup` (generic-password items).
- **Logs**: not yet writing to `~/Library/Logs/HeadsUp/`; current
  diagnostics go through `NSLog`/Console.app only (see Known notes below).

Deleting both the Application Support folder and the Keychain items for that
service is a full reset (equivalent to a fresh install, will require
re-adding accounts and re-entering the OAuth client credentials).

## Debug flags

Pass these as arguments when launching the built executable/app directly
(not meaningful via Finder double-click):

- `--show-main` — opens the main calendar window immediately on launch,
  instead of only the tray icon.
- `--test-alert` — fires a synthetic full-screen alert shortly after launch,
  useful for visually checking the alert window without waiting for a real
  meeting or creating one.

Example:

```bash
swift run HeadsUp -- --show-main --test-alert
```

or, against the signed app bundle:

```bash
"/Applications/Heads Up.app/Contents/MacOS/HeadsUp" --show-main --test-alert
```

## Tests ("checks")

The check suite deliberately depends on neither `XCTest.framework` nor the
`swift-testing` module, so it runs on a machine with only the Xcode Command
Line Tools (where `swift test` cannot). Instead, `HeadsUpKit` is built with
`-enable-testing` in debug and a standalone executable target,
`HeadsUpChecks`, exercises it directly with a small hand-rolled assertion
kit (`Sources/HeadsUpChecks/TestKit.swift`) instead of an XCTest harness.

```bash
swift run HeadsUpChecks
```

This runs 73 checks across design tokens, settings persistence, meeting-link
classification, event normalization, the Keychain-backed secret store, PKCE,
the loopback OAuth redirect server, OAuth error classification, the
multi-account registry, the calendar client, the scheduler, the tray model,
the calendar list model, and settings view logic. All are expected to pass
(`passed 73, failed 0`) on a clean checkout.

`HeadsUpChecks` is a plain command-line target: it does not create an
`NSApplication` or open any window, so it is safe to run in the background,
including while other GUI work is happening on the same Mac.

## Relationship to `GLAZE ORIGINAL/`

`GLAZE ORIGINAL/` is the archived source of the original Electron/TypeScript
version of Heads Up (built via Glaze): `main/`, `renderer/`, the HTML windows
(`alert-window.html`, `main-window.html`, `settings-window.html`), and
`glaze.ts`. It is kept for reference only (feature parity checks, UI copy,
original icon assets) and is not part of the Swift build; nothing in
`Package.swift` or `build_app.sh` touches it. It can be deleted once nobody
needs to diff behaviour against it, but there is no rush to do so.

## Design system

All design tokens (colors, typography scale, spacing, component metrics)
live in `Sources/HeadsUpKit/DesignSystem/DesignSystem.swift`
(`YCDesignSystem`), a self-contained enum-namespaced token set with no
external dependency. The bundled fonts (DM Sans, DM Mono, Syne) ship as SPM
resources, so the app looks the same on any Mac without installing fonts.

## Known notes

- **`LoopbackRedirectServer` is `@unchecked Sendable`.** Its mutable state
  (`continuation`, `pendingResult`) is only ever read or written under an
  `NSLock`; `listener` and `port` are written once each, synchronously,
  inside `start()`/`stop()`, which the OAuth flow that owns the instance is
  expected to call from a single context, not from the connection-handling
  closures that run on Network.framework's own queues. This is documented
  inline at the class declaration.
- **File logging to `~/Library/Logs/HeadsUp/` is not yet implemented.**
  Diagnostics currently go through `NSLog` (visible in Console.app), not a
  rotating `os.Logger`-backed file. Flagged here rather than silently left
  out of scope.

## License

Source-available, not open source: you may read the code, build it
unmodified, and run it for personal use, but not modify, redistribute, or
reuse it in other software. See [LICENSE](LICENSE).
