#!/usr/bin/env bash
# release.sh - Builds, signs, notarizes and publishes a Heads Up release.
#
# Normal flow (after one-time setup in docs/RELEASING.md):
#   1. Edit code, bump VERSION, commit everything.
#   2. ./release.sh
# Friends' installed copies pick the update up within 6 hours.
#
#   ./release.sh --dry-run   # build + package only: self-signed, no
#                            # notarization, no tag/push/GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

APP_DISPLAY_NAME="Heads Up"
VERSION=$(tr -d '[:space:]' < VERSION)
TAG="v$VERSION"
OUT="build/release"
DMG="$OUT/HeadsUp-$VERSION.dmg"
ZIP="$OUT/HeadsUp-$VERSION.zip"
FEED_URL_BASE="https://github.com/yoavcaspi1/heads-up/releases/download/$TAG"

echo "==> Preflight ($VERSION, dry-run=$DRY_RUN)"
[[ -n "$(git status --porcelain)" ]] && { echo "Error: working tree not clean" >&2; exit 1; }
[[ "$(git branch --show-current)" != "main" ]] && { echo "Error: not on main" >&2; exit 1; }
if [[ "$DRY_RUN" == "false" ]]; then
    git rev-parse "$TAG" >/dev/null 2>&1 && { echo "Error: tag $TAG already exists; bump VERSION" >&2; exit 1; }
    security find-identity -v -p codesigning | grep -q "Developer ID Application" \
        || { echo "Error: no Developer ID Application identity in Keychain" >&2; exit 1; }
    xcrun notarytool history --keychain-profile headsup-notary >/dev/null 2>&1 \
        || { echo "Error: notarytool profile 'headsup-notary' missing (see docs/RELEASING.md)" >&2; exit 1; }
    [[ -f "sparkle_public_key.txt" ]] || { echo "Error: sparkle_public_key.txt missing (see docs/RELEASING.md)" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "Error: gh not authenticated" >&2; exit 1; }
fi

# Build from a neutral /tmp clone: SPM bakes the absolute build path into
# the binary (Bundle.module fallback), and the real checkout's path contains
# personal info that must not ship.
BUILD_SRC=$(mktemp -d /tmp/headsup-release.XXXXXX)
trap 'rm -rf "$BUILD_SRC"' EXIT
echo "==> Building universal release bundle in $BUILD_SRC"
git clone --quiet . "$BUILD_SRC"
pushd "$BUILD_SRC" >/dev/null
if [[ "$DRY_RUN" == "true" ]]; then
    HEADSUP_UNIVERSAL=true ./build_app.sh release --no-install
else
    DEV_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" \
        | head -1 | sed 's/.*"\(.*\)"/\1/')
    HEADSUP_SIGN_IDENTITY="$DEV_ID" HEADSUP_UNIVERSAL=true HEADSUP_HARDENED=true \
        ./build_app.sh release --no-install
fi
popd >/dev/null
APP="$BUILD_SRC/build/$APP_DISPLAY_NAME.app"

echo "==> Scanning binary for personal paths"
if strings "$APP/Contents/MacOS/HeadsUp" | grep -E "/Users/|CBD Dropbox"; then
    echo "Error: personal path leaked into the binary (see matches above)" >&2
    exit 1
fi
# Absolute rpaths from the build machine leak paths too; strip any.
otool -l "$APP/Contents/MacOS/HeadsUp" | grep -A2 LC_RPATH | grep " path /" \
    | awk '{print $2}' | while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/HeadsUp"
    echo "    stripped rpath $rp"
done

if [[ "$DRY_RUN" == "false" ]]; then
    # rpath surgery invalidates the signature; re-sign the outer bundle.
    DEV_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" \
        | head -1 | sed 's/.*"\(.*\)"/\1/')
    codesign -f -o runtime --timestamp -s "$DEV_ID" "$APP"

    echo "==> Notarizing (this takes a few minutes)"
    NOTARIZE_ZIP=$(mktemp -d)/notarize.zip
    ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile headsup-notary --wait
    xcrun stapler staple "$APP"
fi

echo "==> Packaging DMG and zip"
rm -rf "$OUT"; mkdir -p "$OUT"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_DISPLAY_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Signing the update zip (Sparkle EdDSA)"
SIGN_TOOL=$(find "$BUILD_SRC/.build/artifacts" -name sign_update -type f -perm +111 2>/dev/null | head -1)
if [[ -z "$SIGN_TOOL" ]]; then
    echo "Error: sign_update tool not found under .build/artifacts" >&2
    exit 1
fi
if [[ "$DRY_RUN" == "true" ]]; then
    # No EdDSA key needed for a dry run; use a placeholder signature.
    ED_ATTRS='sparkle:edSignature="DRY-RUN" length="0"'
else
    ED_ATTRS=$("$SIGN_TOOL" "$ZIP")   # emits: sparkle:edSignature="..." length="..."
fi

echo "==> Writing appcast.xml"
PUBDATE=$(date -R)
cat > appcast.xml <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Heads Up</title>
    <item>
      <title>Heads Up $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$FEED_URL_BASE/HeadsUp-$VERSION.zip" $ED_ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST

if [[ "$DRY_RUN" == "true" ]]; then
    git checkout -- appcast.xml 2>/dev/null || rm -f appcast.xml
    echo "==> Dry run complete: $DMG / $ZIP (appcast not kept, nothing pushed)"
    exit 0
fi

echo "==> Publishing"
NOTES=$(git log --format='- %s' "$(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~10)"..HEAD | head -20)
git add appcast.xml
git commit -m "release: Heads Up $VERSION"
git tag "$TAG"
git push origin main "$TAG"
gh release create "$TAG" "$DMG" "$ZIP" --title "Heads Up $VERSION" --notes "$NOTES"
echo "==> Done. Installed apps update within 6 hours."
