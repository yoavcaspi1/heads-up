# Heads Up

A native macOS menu-bar app that watches your Google Calendar and puts a
full-screen alert in front of you before each meeting starts.

The app lives entirely in the menu bar (no Dock icon). It shows the next
or current meeting's countdown/status in the tray, opens a calendar list
window on click, and fires a full-screen "you're up" alert a configurable
number of minutes before each meeting.

## What it does

- Signs in to one or more Google accounts (read-only calendar access).
- Shows the next/ongoing meeting in the menu bar with a live countdown.
- Fires a full-screen alert before each meeting, with snooze.
- Click the menu-bar bell for the day-by-day meeting list; right-click
  for settings, the setup guide and updates.

## Install

1. Download `HeadsUp-<latest>.dmg` from the
   [Releases page](https://github.com/yoavcaspi1/heads-up/releases/latest).
2. Open it and drag **Heads Up** into the **Applications** folder.
3. Open Heads Up from Applications. Look for the bell icon in the menu
   bar, at the top right of the screen.

On first launch the app opens a **Setup Guide** that walks you through
connecting your Google Calendar. It takes about 10 minutes, once. The
guide is also available any time: right-click the bell icon and choose
"Setup Guide…".

Requires macOS 14 (Sonoma) or later. No Terminal, no other installs.

## Google setup, step by step

The in-app Setup Guide covers all of this interactively; this is the
same walkthrough in written form. Heads Up connects through your own
Google OAuth client, so your calendar data never goes through anyone
else's account; there is no shared/bundled client ID.

1. **Create a Google Cloud project** at
   https://console.cloud.google.com/projectcreate. Any name. Free.
2. **Enable the Calendar API**: open
   https://console.cloud.google.com/apis/library/calendar-json.googleapis.com
   with your project selected and press Enable.
3. **Configure the consent screen** at
   https://console.cloud.google.com/apis/credentials/consent: choose
   External, fill the required fields (app name, your email), save
   through the steps, then press **Publish app**. Publishing matters:
   in Testing mode Google disconnects the app every 7 days.
4. **Create credentials** at
   https://console.cloud.google.com/apis/credentials/oauthclient:
   type "Desktop app". Copy the Client ID and Client secret into the
   app's Setup Guide (or Settings > Google connection).
5. **Sign in** from the Setup Guide. Google shows an "unverified app"
   warning because the project is yours and brand new: click Advanced,
   then "Go to Heads Up (unsafe)", then allow calendar access. Repeat
   for each Google account you want alerts from; the client ID/secret
   is shared across all accounts added this way.

During sign-in, Heads Up opens your default browser to Google's consent
screen and receives the redirect on a one-shot, loopback-only listener
on `127.0.0.1` (ephemeral port, PKCE-protected). No fixed redirect URI
needs to be registered for a Desktop app client.

## Updates

Heads Up updates itself: it checks for new releases every 6 hours,
downloads them automatically, and installs on relaunch. To check
manually, right-click the bell icon and choose "Check for Updates…".

## Where data lives

- **Settings and account list**: JSON files in
  `~/Library/Application Support/HeadsUp/`
  - `settings.json` — lead times, enabled calendars, appearance, etc.
  - `accounts.json` — the list of connected Google accounts and their
    per-account state (reconnect-needed flags, etc.). Tokens themselves are
    not in this file.
  - `setup_wizard.json` — how far the Setup Guide got, so it can resume.
- **OAuth client secret and per-account tokens**: macOS Keychain, service
  name `com.eloryo.headsup` (generic-password items). Installs predating the
  rename hold their items under `com.cedoreholdings.headsup`; the app moves
  them across silently on first launch of a version that has this change,
  then deletes the old items.
- **Logs**: not yet writing to `~/Library/Logs/HeadsUp/`; current
  diagnostics go through `NSLog`/Console.app only (see Known notes below).

Deleting both the Application Support folder and the Keychain items for that
service is a full reset (equivalent to a fresh install, will require
re-adding accounts and re-entering the OAuth client credentials).

## For developers

Everything below is for building from source. If you just want to use
the app, the [Install](#install) section above is all you need.

### Requirements

- macOS 14.0 (Sonoma) or later.
- Swift 5.10+ / Xcode Command Line Tools. A full Xcode install is not
  required to build from the command line, but Xcode can also open the
  package directly (`File > Open` on the folder, or `open Package.swift`) for
  GUI debugging.
- One SPM dependency: [Sparkle 2](https://github.com/sparkle-project/Sparkle)
  (auto-updates), resolved automatically by `swift build`.

### Building

#### Command line (SPM)

```bash
swift build                # debug build, compiles the HeadsUp executable target
swift build -c release     # release build
swift run HeadsUpChecks    # runs the full check suite (see "Tests" below)
```

`swift build` alone produces a bare executable, not a double-clickable
`.app`. For a real app bundle, use `build_app.sh` (below).

#### Xcode GUI

Open the folder in Xcode (`open Package.swift` or drag the folder onto
Xcode). Xcode resolves the SPM package automatically, exposes the `HeadsUp`
and `HeadsUpChecks` schemes, and can build/run/debug either target
interactively. `HeadsUpKit` (the shared library target) is not directly
runnable; it is exercised through the other two.

#### `build_app.sh` (proper `.app` bundle)

```bash
./build_app.sh                 # debug build, installs to /Applications and relaunches
./build_app.sh release          # optimized release build
./build_app.sh --no-install     # build and sign only, skip install/relaunch
./build_app.sh --force          # skip waiting for a running instance to quit first
```

This wraps `swift build`, assembles `build/Heads Up.app` (Info.plist,
bundled fonts, app icon, embedded Sparkle.framework), code-signs it, and
by default installs it to `/Applications/Heads Up.app` and relaunches it.
`--no-install` is the safe option when you just want a signed bundle
without touching a running instance (for example, while a recording or
call is in progress on this machine — never quit/relaunch the app
mid-call).

**Do not run `build_app.sh` without `--no-install` while the app is actively
being used for something time-sensitive** (an armed alert about to fire, a
call in progress on the same machine). It force-quits any running instance
before installing.

Maintainer releases (signing, notarization, publishing) are driven by
`release.sh`; see `docs/RELEASING.md`.

#### One-time code-signing certificate

`build_app.sh` refuses to run with ad-hoc signing, because ad-hoc signatures
change on every build and macOS treats that as a "new app," resetting all TCC
permission grants (Notifications, etc.) each time. For local dev builds it
signs with a stable self-signed identity named `HeadsUp Developer` (release
builds use the maintainer's Developer ID instead), which must be created
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

### Keychain access prompts

A Keychain item remembers which code may read it, as a code-signing
requirement recorded in the item's access-control list. For an app signed
with a self-signed certificate that requirement is `identifier "<bundle id>"
and certificate leaf = H"<cert hash>"`, so it covers the bundle identifier as
well as the certificate.

**1.2.0 renamed the bundle identifier** from `com.cedoreholdings.headsup` to
`com.yoavcaspi.headsup`, which means existing items no longer match. On the
first launch after updating, macOS asks once per stored item (the OAuth
client credentials, plus one token item per connected Google account):

> Heads Up wants to use information stored in "com.eloryo.headsup" in your
> keychain.

**Click "Always Allow".** That adds the renamed app to the item's
access-control list permanently, and nothing is asked again. "Allow" grants
access for that launch only, so the dialog returns on the next one.

Nothing is lost if the prompt is dismissed or denied: the app treats an
unreadable item exactly as it treats a missing one, so it falls back to the
normal "not connected" state and offers to re-run the OAuth flow, and the
prompt reappears on the next launch. Be aware of one wrinkle if you go that
route rather than allowing access: writing a secret needs no read access, so
re-authenticating into an item the app still cannot read will appear to work
and then come up empty again. The app detects this and logs

> HeadsUp Keychain wrote … but cannot read it back

to Console. There is no way to repair the access-control list from code (both
deleting and re-adding the item are refused for the same reason), so the fix
is to answer the prompt with Always Allow, or to delete the
`com.eloryo.headsup` items in Keychain Access and set the app up again.

The same mechanism, for the certificate half of the requirement rather than
the identifier half, is why a rebuild can re-raise the dialog. The durable
fix for that is to trust the certificate: in Keychain Access, double-click
**HeadsUp Developer**, expand **Trust**, and set **Code Signing** to **Always
Trust** (admin password required).

### Debug flags

Pass these as arguments when launching the built executable/app directly
(not meaningful via Finder double-click):

- `--show-main` — opens the main calendar window immediately on launch,
  instead of only the tray icon.
- `--test-alert` — fires a synthetic full-screen alert shortly after launch,
  useful for visually checking the alert window without waiting for a real
  meeting or creating one.
- `--setup-wizard` — forces the Setup Guide window open on launch even when
  credentials already exist.

Example:

```bash
swift run HeadsUp -- --show-main --test-alert
```

or, against the signed app bundle:

```bash
"/Applications/Heads Up.app/Contents/MacOS/HeadsUp" --show-main --test-alert
```

### Tests ("checks")

The check suite deliberately depends on neither `XCTest.framework` nor the
`swift-testing` module, so it runs on a machine with only the Xcode Command
Line Tools (where `swift test` cannot). Instead, `HeadsUpKit` is built with
`-enable-testing` in debug and a standalone executable target,
`HeadsUpChecks`, exercises it directly with a small hand-rolled assertion
kit (`Sources/HeadsUpChecks/TestKit.swift`) instead of an XCTest harness.

```bash
swift run HeadsUpChecks
```

The checks cover design tokens, settings persistence, meeting-link
classification, event normalization, the Keychain-backed secret store, PKCE,
the loopback OAuth redirect server, OAuth error classification, the
multi-account registry, the calendar client, the scheduler, the tray model,
the calendar list model, settings view logic, and the setup wizard. All are
expected to pass (`failed 0`) on a clean checkout.

`HeadsUpChecks` is a plain command-line target: it does not create an
`NSApplication` or open any window, so it is safe to run in the background,
including while other GUI work is happening on the same Mac.

### Relationship to `GLAZE ORIGINAL/`

`GLAZE ORIGINAL/` is the archived source of the original Electron/TypeScript
version of Heads Up (built via Glaze): `main/`, `renderer/`, the HTML windows
(`alert-window.html`, `main-window.html`, `settings-window.html`), and
`glaze.ts`. It is kept for reference only (feature parity checks, UI copy,
original icon assets) and is not part of the Swift build; nothing in
`Package.swift` or `build_app.sh` touches it. It can be deleted once nobody
needs to diff behaviour against it, but there is no rush to do so.

### Design system

All design tokens (colors, typography scale, spacing, component metrics)
live in `Sources/HeadsUpKit/DesignSystem/DesignSystem.swift`
(`YCDesignSystem`), a self-contained enum-namespaced token set with no
external dependency. The bundled fonts (DM Sans, DM Mono, Syne) ship as SPM
resources, so the app looks the same on any Mac without installing fonts.

### Known notes

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
