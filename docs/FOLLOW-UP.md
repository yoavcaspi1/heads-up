# Heads Up - Follow-up list (post swift-port)

Carried from the per-task and final reviews of 29 Jul 2026. None block the merge.

## Needs a supervised session (owner present, no live call on the Mac)

1. Create the one-time `HeadsUp Developer` self-signed code-signing certificate (Keychain Access: Certificate Assistant, Create a Certificate, type Code Signing, name exactly `HeadsUp Developer`), then `./build_app.sh` to install to /Applications.
2. Create a Google OAuth client of type Desktop app in the existing Cloud project (Calendar API already enabled), enter client ID + secret in Settings, connect accounts.
3. Live verification sweep, remaining items: snooze re-show, Join button, multi-display coverage, dark mode pass, kill-and-relaunch re-arm, tray countdown with real meetings. (Done 29 Jul 2026: real Escape keypress verified against a background-fired alert with focus diagnostics active=true key=true; events-populated calendar rows verified live; alert appearance now refreshes live from Settings.)
4. Decide on retiring the Glaze-hosted app (/Applications/Glaze/Heads Up.app) once the native app is trusted; both running together means duplicate alerts.

## Code follow-ups (small, non-blocking)

- Keychain prompts on rebuilds: the self-signed HeadsUp Developer cert is untrusted, so each newly signed build can re-trigger the keychain permission dialog for the stored credentials/tokens. Durable fix: in Keychain Access, double-click the HeadsUp Developer certificate, expand Trust, set Code Signing to Always Trust (admin password required). Until then, click Always Allow once per new build. The app now survives an unanswered prompt (tray/menu/quit stay alive; calendar loads after the prompt is answered).

- Per-account wholesale failure while another account succeeds replaces the cache without the failed account's events (pre-existing degrade contract; consider per-account cache retention).
- Scheduler/SettingsStore main-thread confinement is by convention; revisit with strict concurrency when full Xcode is available (would also allow porting HeadsUpChecks back to XCTest).

## Design system back-port (into the upstream token JSON + DesignSystem.swift)

- `type.displayXL` (Syne ExtraBold 64), `type.dataLarge` (DM Mono Medium 24).
- Tray tint tokens: harbor #3E6E93 (active), sage #3F6A4E (done).
- Consider `layout.controlHeight` (36/44) token so the named literal exceptions become real tokens. (`preferences.rowMinHeight` landed 29 Jul 2026, see Done below.)

## Done (29 Jul 2026)

- Calendar events pagination: `fetchEvents` now follows `nextPageToken`, capped at 5 pages per calendar.
- OAuth loopback 300s timeout now maps to `OAuthError.transport("Sign-in timed out, please try again")` instead of a generic transport error.
- PKCE: `SecRandomCopyBytes` status is captured and asserted via `precondition`.
- Scheduler: `fired` is pruned in `rescheduleNow` to bound memory over long uptimes; added `removeAccountsStateChangedObserver` for symmetry with the events observer; a snooze re-show now checks `alertsEnabled` before firing (still clears the snooze state either way) so a mid-snooze master-switch-off does not re-trigger the alert.
- Debounced the blur-intensity slider: drags a local `@State` value and only persists via the model (and reschedules) once dragging ends.
- Alert background staleness: `AlertWindowController` now remembers the `AlertBackground` mode its windows were built with and rebuilds (rather than content-swaps) when the setting changes while an alert is up, since `isOpaque` is fixed at panel creation.
- Extracted `CalendarListModel.sections` bucketing into the pure static `CalendarListModel.bucketed(_:today:calendar:)`; the checks now call it directly, and the weekday-format check asserts the exact `"EEEE d MMM"` string for a fixed date.
- Settings rows: added `YCDesignSystem.Rows.minHeight` (48pt, back-port to the upstream token JSON as `preferences.rowMinHeight`) and applied `.frame(minHeight:)` to the shared `settingsRow` scaffold.
- TrayModel: the clock `DateFormatter` is now a cached `static let`.
- AlertView: "Until event" boundary changed from `> 90` to `>= 90` to match the "disabled under 90 seconds" spec (exactly 90s is now enabled).
