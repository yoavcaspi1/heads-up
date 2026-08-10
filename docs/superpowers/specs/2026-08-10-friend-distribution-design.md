# Heads Up - Friend Distribution Design

Date: 10 Aug 2026
Status: Approved by Yoav (Approach A)

## Goal

Let non-technical friends install Heads Up by downloading it from GitHub,
with a first-run wizard inside the app guiding the one-time Google setup,
and have every installed copy update itself automatically when a new
version is published. The README gains a clear download-first install
guide, with developer material moved behind it.

## Context and constraints

- The audience is mostly non-technical: no Terminal, no git, no Keychain
  Access, no build commands.
- Each friend creates their own Google OAuth client (decided against
  sharing one client). The in-app wizard therefore carries the full
  weight of that flow.
- Distribution is a prebuilt app downloaded from GitHub Releases. This
  invalidates the current update mechanism (poll `VERSION`, `git pull`,
  rebuild via `build_app.sh`), which requires a kept checkout and build
  tools.
- Yoav is enrolling in the Apple Developer Program (Developer ID
  certificate). Release builds will be signed and notarized so the
  downloaded app opens with no Gatekeeper warnings.
- License stays the custom source-available one; no change.
- The public repo must stay free of personal information and of all
  private keys (Developer ID identity, Sparkle private key, notarization
  credentials).

## Component 1: Sparkle 2 auto-updates (replaces UpdateChecker)

**Remove** `Sources/HeadsUpKit/Services/UpdateChecker.swift` and its
git-pull/rebuild flow, the tray menu's "Update to X.Y.Z" rebuild action,
and `Sources/HeadsUpChecks/UpdateCheckerChecks.swift`.

**Add** Sparkle 2.x as the project's first SPM dependency
(`https://github.com/sparkle-project/Sparkle`, major version 2).

Configuration (Info.plist keys written by `build_app.sh`):

- `SUFeedURL` = `https://raw.githubusercontent.com/yoavcaspi1/heads-up/main/appcast.xml`
- `SUPublicEDKey` = the Sparkle EdDSA public key (embedded, safe to publish)
- `SUEnableAutomaticChecks` = YES
- `SUScheduledCheckInterval` = 21600 (6 hours)
- `SUAutomaticallyUpdate` = YES (download and install without prompting;
  installs on quit or offers a relaunch)

Wiring: instantiate `SPUStandardUpdaterController` in `AppDelegate`; add
a "Check for Updates…" item to the tray right-click menu for manual
checks. Updater UI beyond that is Sparkle's stock UI.

Dev-build behaviour: local debug builds built straight from a checkout
keep Sparkle enabled; Sparkle only offers versions strictly newer than
the running one, so dev builds at the current version are unaffected.

The `VERSION` file remains the single source of truth for the app
version; `build_app.sh` continues stamping it into
`CFBundleShortVersionString`. `CFBundleVersion` uses `build_number.txt`
as today, and the appcast compares versions via
`sparkle:shortVersionString`/`sparkle:version` from the release script.

## Component 2: Release pipeline (`release.sh`)

New script at the repo root, run only on Yoav's Mac. Steps, in order,
failing loudly on any error:

1. Preflight: clean git tree, on `main`, `VERSION` newer than the last
   released tag, Developer ID certificate present, notarization
   credentials profile present, Sparkle private key present in Keychain,
   `gh` authenticated.
2. Build a universal (arm64 + x86_64) release binary via
   `swift build -c release --arch arm64 --arch x86_64`.
3. Assemble `build/Heads Up.app` (reusing `build_app.sh` bundle logic),
   sign with the Developer ID Application identity and hardened runtime.
4. Notarize with `xcrun notarytool submit --wait` and staple the ticket.
5. Package:
   - `HeadsUp-X.Y.Z.dmg` - human download; app + /Applications symlink.
   - `HeadsUp-X.Y.Z.zip` - Sparkle update artifact.
6. Sign the zip with Sparkle's `sign_update` (EdDSA signature).
7. Regenerate `appcast.xml` (top entry: new version, release notes from
   a short changelog block, zip URL pointing at the GitHub Release
   asset, EdDSA signature, minimum system version 14.0).
8. Commit `appcast.xml` + `VERSION` + `build_number.txt`, tag `vX.Y.Z`,
   push `main` and the tag.
9. `gh release create vX.Y.Z` with the DMG and zip attached and the
   changelog as release notes.

One-time prerequisites (documented in the script header and in
`docs/RELEASING.md`, a new short internal doc):

- Apple Developer Program enrollment; Developer ID Application cert in
  Keychain.
- `xcrun notarytool store-credentials` profile named `headsup-notary`.
- Sparkle EdDSA keypair via `generate_keys` (private key lands in the
  login Keychain; public key goes into `build_app.sh`).

Update workflow after this ships: edit code, bump `VERSION`, run
`./release.sh`. Friends' apps update within 6 hours.

## Component 3: First-run setup wizard (in-app live instructions)

New SwiftUI window, styled with `YCDesignSystem`, shown automatically at
launch when no Google OAuth client credentials are stored; reachable any
time from the tray right-click menu as "Setup Guide…". Closing it
mid-way is allowed; it reopens at the saved step on next launch until
the user has passed step 5 (client credentials saved). After that it
never auto-opens again, even if step 6 was skipped - the tray menu
entry remains the way back in.

Structure: a step model (`SetupWizardModel`) in `HeadsUpKit`, pure logic,
covered by checks; a `SetupWizardView` + window controller for chrome.

Steps:

1. **Welcome.** What Heads Up does; setup needs a Google account and
   about 10 minutes, one time only.
2. **Create a Google Cloud project.** Button opens
   `https://console.cloud.google.com/projectcreate`. Instruction: any
   project name, click Create, wait for the notification.
3. **Enable the Google Calendar API.** Button opens the Calendar API
   library page. Instruction: click Enable.
4. **Consent screen, then publish to Production.** Buttons open the
   consent-screen config. Instructions: External type, app name + own
   email, add own email as developer contact, save through the steps,
   then **Publish app** (Testing mode makes Google expire sign-ins every
   7 days; the wizard states this explicitly as the reason).
5. **Create the OAuth client.** Button opens the Credentials page.
   Instructions: Create credentials > OAuth client ID > Desktop app.
   Two paste fields: Client ID (validated: non-empty, ends in
   `.apps.googleusercontent.com`) and Client secret (non-empty). Save
   stores them via the existing `GoogleCredentialsStore` /
   `KeychainSecretStore`.
6. **Sign in.** Runs the existing OAuth flow. Inline note prepares them
   for Google's "unverified app" interstitial: click "Advanced", then
   "Go to <app name> (unsafe)" - expected, one time, their own project.
   Success shows account email + calendar count via existing services.
7. **Done.** Points at the menu-bar icon, mentions alerts and that
   updates are automatic. Button: "Finish".

Each step has Back/Next; steps 2-4 advance with "Done, next" (no
verifiable signal available); step 5 validates before enabling Next;
step 6 requires a successful sign-in to advance (or "Skip for now").

The existing Settings window keeps its credentials section unchanged -
the wizard is a guided front-end over the same stores, not a
replacement.

## Component 4: README rewrite

New order and content:

1. Title + one-paragraph description (kept).
2. **Install** - the friend path: link to the Releases page, download
   the DMG, drag to Applications, open; first launch walks through
   Google setup (~10 min, one time). No Terminal anywhere.
3. **Google setup reference** - numbered manual mirror of wizard steps
   2-6, for people who close the wizard or want to read ahead. Includes
   the publish-to-Production explanation and the unverified-app
   interstitial note.
4. **Updates** - automatic; how to check manually (tray menu); where
   update logs live.
5. **Where data lives** (kept, updated).
6. **For developers** - everything currently in the top half moves
   here: build from source (SPM/Xcode/`build_app.sh`), the self-signed
   `HeadsUp Developer` certificate for local dev builds, debug flags,
   tests/checks (with the stale "73 checks" count replaced by "all
   checks pass" so it cannot drift again), `GLAZE ORIGINAL/` note,
   design system, known notes.
7. **License** (kept).

`build_app.sh` stays the local-dev install path (self-signed cert,
installs to /Applications); `release.sh` is the only path producing
distributable artifacts.

## Testing

- `HeadsUpChecks` gains `SetupWizardModelChecks`: step ordering,
  advance/back gating, client-ID validation, persistence of a partial
  wizard state, completion condition. Removes `UpdateCheckerChecks`.
  Suite must stay green (`swift run HeadsUpChecks`).
- Sparkle wiring smoke-checked by building the app and verifying the
  Info.plist keys and framework presence (scripted check inside
  `release.sh` preflight, plus manual first-release test).
- End-to-end update test after enrollment clears: install release
  vX.Y.Z on a second Mac, publish vX.Y.Z+1, verify silent update within
  a manual "Check for Updates…".
- Wizard walked through manually once against a throwaway Google Cloud
  project.

## Sequencing

1. Now (no external dependency): wizard, Sparkle integration, README
   rewrite, `release.sh`, `docs/RELEASING.md`, check-suite updates. All
   committed to `main` but not released.
2. Yoav enrolls at developer.apple.com (1-2 days approval), then the
   one-time credential setup (Developer ID cert, notary profile,
   Sparkle keys).
3. First signed release (v1.3.0; 1.2.0 already shipped via the old
   updater on 10 Aug 2026): run `release.sh`, verify a friend-path
   install on a second Mac, then share the repo link.
4. Yoav's own Macs switch to the released build to dogfood the same
   artifact friends run.

## Out of scope

- Sharing a Google OAuth client (explicitly decided against).
- Windows/Linux, Mac App Store, Homebrew cask.
- Changing the license or accepting outside contributions.
- Delta updates, release channels, beta feeds.
