# Releasing Heads Up

Internal notes for the maintainer. Friends never need this file.

## One-time setup (after Apple Developer enrollment)

1. **Developer ID certificate.** In Xcode: Settings > Accounts > your
   Apple ID > Manage Certificates > + > Developer ID Application. Or via
   https://developer.apple.com/account/resources/certificates. Verify:
   `security find-identity -v -p codesigning | grep "Developer ID"`.
2. **Notarization credentials.** Create an app-specific password at
   https://account.apple.com (Sign-In and Security > App-Specific
   Passwords), then:
   `xcrun notarytool store-credentials headsup-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password APP_SPECIFIC_PASSWORD`
3. **Sparkle signing keys.** Run
   `$(find .build/artifacts -name generate_keys -type f | head -1)`.
   The private key lands in the login Keychain (item "Private key for
   signing Sparkle updates" - NEVER export or commit it). Save the
   printed public key:
   `echo "PASTE_PUBLIC_KEY" > sparkle_public_key.txt` and commit that
   file (public keys are safe to publish).

4. **Bundled Google OAuth client.** Release builds refuse to build
   without one. Put the Desktop-app client from the Heads Up Google
   Cloud project in `~/.config/headsup/google-oauth-client.env`
   (mode 600, never committed):
   ```
   HEADSUP_GOOGLE_CLIENT_ID=...apps.googleusercontent.com
   HEADSUP_GOOGLE_CLIENT_SECRET=GOCSPX-...
   ```
   `build_app.sh` writes both into Info.plist. The project's consent
   screen must be **published to production** (Google Auth Platform >
   Audience), otherwise sign-ins expire after 7 days and only listed
   test users can connect.

## Every release

1. Make the changes; run `swift run HeadsUpChecks` until green.
2. Bump `VERSION` (semantic-ish: X.Y.Z), commit everything.
3. `./release.sh`

That builds a universal binary, signs with Developer ID, notarizes,
staples, packages `HeadsUp-X.Y.Z.dmg` (human download) and `.zip`
(Sparkle update), EdDSA-signs the zip, rewrites `appcast.xml`, commits
and tags, pushes, and creates the GitHub Release with both artifacts.

`./release.sh --dry-run` exercises everything local (self-signed, no
notarization, nothing pushed) - use it to test pipeline changes.

## First-run checklist for a new release machine

- Xcode Command Line Tools, `gh auth login`, plus the three setup steps
  above.
