#!/usr/bin/env bash
# build_app.sh - Builds "Heads Up".app from the SPM target.
#
# This script wraps `swift build` and assembles a proper macOS .app bundle
# that Finder will recognise (Info.plist, LSUIElement, bundle ID, etc.). It
# works with the Command Line Tools install of Swift, no full Xcode required.
#
# Usage:
#   ./build_app.sh                 # debug build, install to /Applications
#   ./build_app.sh release         # optimized release build
#   ./build_app.sh --no-install    # build and sign, skip install/relaunch
#   ./build_app.sh --force         # skip the "quit running instance" wait
#
# Output:
#   build/Heads Up.app
#
set -euo pipefail
cd "$(dirname "$0")"

FORCE_INSTALL=false
NO_INSTALL=false
CONFIG="debug"
for arg in "$@"; do
    case "$arg" in
        --force) FORCE_INSTALL=true ;;
        --no-install) NO_INSTALL=true ;;
        debug|release) CONFIG="$arg" ;;
    esac
done

if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
    echo "Usage: $0 [debug|release] [--no-install] [--force]" >&2
    echo "  --no-install   Build only, do not install to /Applications" >&2
    echo "  --force        Skip waiting for a running instance to quit" >&2
    exit 1
fi

APP_NAME="HeadsUp"
APP_DISPLAY_NAME="Heads Up"
BUNDLE_ID="com.yoavcaspi.headsup"
# release.sh overrides these three for distributable builds.
SIGN_IDENTITY="${HEADSUP_SIGN_IDENTITY:-HeadsUp Developer}"
UNIVERSAL="${HEADSUP_UNIVERSAL:-false}"
HARDENED="${HEADSUP_HARDENED:-false}"

echo "==> Building Swift package ($CONFIG)..."
# Only the app product: HeadsUpChecks needs -enable-testing on HeadsUpKit,
# which is debug-only, so a plain `swift build -c release` cannot build it.
if [[ "$UNIVERSAL" == "true" ]]; then
    # Two single-arch builds + lipo: `swift build --arch a --arch b` needs
    # full Xcode's xcbuild, which a CLT-only machine does not have.
    swift build -c "$CONFIG" --product "$APP_NAME" --triple arm64-apple-macosx
    swift build -c "$CONFIG" --product "$APP_NAME" --triple x86_64-apple-macosx
    BIN_PATH=$(swift build -c "$CONFIG" --triple arm64-apple-macosx --show-bin-path)
    BIN_PATH_X86=$(swift build -c "$CONFIG" --triple x86_64-apple-macosx --show-bin-path)
    EXEC_PATH="$BIN_PATH/$APP_NAME-universal"
    lipo -create "$BIN_PATH/$APP_NAME" "$BIN_PATH_X86/$APP_NAME" -output "$EXEC_PATH"
else
    swift build -c "$CONFIG" --product "$APP_NAME"
    BIN_PATH=$(swift build -c "$CONFIG" --show-bin-path)
    EXEC_PATH="$BIN_PATH/$APP_NAME"
fi

if [[ ! -x "$EXEC_PATH" ]]; then
    echo "Error: built executable not found at $EXEC_PATH" >&2
    exit 1
fi

APP_BUNDLE="build/$APP_DISPLAY_NAME.app"
echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXEC_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy the SPM-bundled resources (fonts, icon) into the app bundle. The
# resources live in the HeadsUpKit library target, so SPM names the
# generated bundle after the package and that target, not after the
# HeadsUp executable.
RES_BUNDLE="$BIN_PATH/${APP_NAME}_HeadsUpKit.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
    cp -R "$RES_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
else
    echo "Warning: SPM resource bundle not found at $RES_BUNDLE" >&2
fi

# Copy the app icon directly too, so CFBundleIconFile resolves it at the top
# level of Contents/Resources (Finder does not look inside the SPM bundle).
if [[ -f "Sources/HeadsUpKit/Resources/AppIcon.icns" ]]; then
    cp "Sources/HeadsUpKit/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
    echo "Warning: AppIcon.icns not found at Sources/HeadsUpKit/Resources/AppIcon.icns" >&2
fi

# Embed Sparkle.framework (SPM ships it as a prebuilt universal artifact).
SPARKLE_FW=$(find .build/artifacts -type d -name "Sparkle.framework" \
    -not -path "*dSYM*" 2>/dev/null | head -1)
if [[ -z "$SPARKLE_FW" ]]; then
    echo "Error: Sparkle.framework not found under .build/artifacts (run swift build first)" >&2
    exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/"
# The executable references @rpath/Sparkle...; point rpath at Frameworks.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# ============================================================================
# Info.plist generation: marketing version from the VERSION file (also what
# the in-app update check compares against the repo), plus an incrementing
# local build number (untracked, per machine).
# ============================================================================
SHORT_VERSION="1.0.0"
if [[ -f "VERSION" ]]; then
    SHORT_VERSION=$(tr -d '[:space:]' < VERSION)
fi

# CFBundleVersion = git commit count: deterministic (same commit -> same
# build number, including in release.sh's neutral clone), monotonically
# increasing across releases, and what Sparkle compares via the appcast's
# sparkle:version. Falls back to 1 outside a git checkout.
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)

SPARKLE_KEY_XML=""
if [[ -f "sparkle_public_key.txt" ]]; then
    SPARKLE_KEY_XML="    <key>SUPublicEDKey</key>
    <string>$(tr -d '[:space:]' < sparkle_public_key.txt)</string>"
else
    echo "Warning: sparkle_public_key.txt missing; update signatures will not verify" >&2
fi

# Bundled Google OAuth client. Never in git: read from the environment or
# from ~/.config/headsup/google-oauth-client.env, and written into
# Info.plist so users only have to sign in. Without it the app asks for a
# client of the user's own (the pre-1.5 flow). Release builds must have it.
CLIENT_ENV="$HOME/.config/headsup/google-oauth-client.env"
if [[ -z "${HEADSUP_GOOGLE_CLIENT_ID:-}" && -f "$CLIENT_ENV" ]]; then
    set -a; source "$CLIENT_ENV"; set +a
fi
GOOGLE_CLIENT_XML=""
if [[ -n "${HEADSUP_GOOGLE_CLIENT_ID:-}" && -n "${HEADSUP_GOOGLE_CLIENT_SECRET:-}" ]]; then
    GOOGLE_CLIENT_XML="    <key>HeadsUpGoogleClientID</key>
    <string>$HEADSUP_GOOGLE_CLIENT_ID</string>
    <key>HeadsUpGoogleClientSecret</key>
    <string>$HEADSUP_GOOGLE_CLIENT_SECRET</string>"
    echo "==> Bundling Google OAuth client ${HEADSUP_GOOGLE_CLIENT_ID%%-*}-…"
elif [[ "$HARDENED" == "true" ]]; then
    echo "Error: no Google OAuth client to bundle. Set HEADSUP_GOOGLE_CLIENT_ID and" >&2
    echo "HEADSUP_GOOGLE_CLIENT_SECRET, or create $CLIENT_ENV (see docs/RELEASING.md)." >&2
    exit 1
else
    echo "Warning: no Google OAuth client bundled; the app will ask for the user's own" >&2
fi

echo "==> Writing Info.plist (version $SHORT_VERSION, build $BUILD_NUMBER)"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/yoavcaspi1/heads-up/main/appcast.xml</string>
$SPARKLE_KEY_XML
$GOOGLE_CLIENT_XML
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>21600</integer>
    <key>SUAutomaticallyUpdate</key>
    <true/>
</dict>
</plist>
PLIST

# ============================================================================
# Code signing
# ============================================================================
echo "==> Signing with $SIGN_IDENTITY certificate"

# Check if our signing identity exists. Ad-hoc signing (-) is DISABLED
# because it resets TCC permissions on every deploy. Verify by attempting an
# actual test-sign, since self-signed certs can show as "invalid" under
# 'security find-identity' even though codesign accepts them.
_sign_test="$(mktemp)"; cp /bin/ls "$_sign_test"
if ! codesign -f -s "$SIGN_IDENTITY" "$_sign_test" >/dev/null 2>&1; then
    rm -f "$_sign_test"
    echo "" >&2
    echo "===============================================================================" >&2
    echo "ERROR: Code signing certificate '$SIGN_IDENTITY' not found!" >&2
    echo "" >&2
    echo "Ad-hoc signing (-) is DISABLED because it resets TCC permissions on every" >&2
    echo "deploy. You must create a self-signed code-signing certificate named" >&2
    echo "'$SIGN_IDENTITY' in Keychain Access (Keychain Access > Certificate" >&2
    echo "Assistant > Create a Certificate, Identity Type: Self Signed Root," >&2
    echo "Certificate Type: Code Signing)." >&2
    echo "" >&2
    echo "To check available identities: security find-identity -v -p codesigning" >&2
    echo "===============================================================================" >&2
    echo "" >&2
    exit 1
fi
rm -f "$_sign_test"

SIGN_FLAGS=(-f -s "$SIGN_IDENTITY")
if [[ "$HARDENED" == "true" ]]; then
    SIGN_FLAGS+=(-o runtime --timestamp)
fi
FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [[ -d "$FW" ]]; then
    for xpc in "$FW/Versions/B/XPCServices/"*.xpc; do
        [[ -d "$xpc" ]] && codesign "${SIGN_FLAGS[@]}" "$xpc"
    done
    [[ -f "$FW/Versions/B/Autoupdate" ]] && codesign "${SIGN_FLAGS[@]}" "$FW/Versions/B/Autoupdate"
    [[ -d "$FW/Versions/B/Updater.app" ]] && codesign "${SIGN_FLAGS[@]}" "$FW/Versions/B/Updater.app"
    codesign "${SIGN_FLAGS[@]}" "$FW"
fi
codesign "${SIGN_FLAGS[@]}" -i "$BUNDLE_ID" "$APP_BUNDLE"

echo "==> Verifying code signature..."
if codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1; then
    echo "    Signature verification PASSED"
else
    echo "    WARNING: Signature verification had issues (see above)"
fi

# ============================================================================
# Install
# ============================================================================
if [[ "$NO_INSTALL" == "true" ]]; then
    echo "==> Skipping install (--no-install specified)"
else
    echo "==> Quitting any running instance of $APP_DISPLAY_NAME"
    osascript -e "tell application \"$APP_DISPLAY_NAME\" to quit" >/dev/null 2>&1 || true
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    if [[ "$FORCE_INSTALL" != "true" ]]; then
        for _ in $(seq 1 20); do
            pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
            sleep 0.5
        done
    fi

    echo "==> Installing to /Applications/$APP_DISPLAY_NAME.app"
    rm -rf "/Applications/$APP_DISPLAY_NAME.app"
    ditto "$APP_BUNDLE" "/Applications/$APP_DISPLAY_NAME.app"
    echo "    Installed: /Applications/$APP_DISPLAY_NAME.app"

    echo "==> Launching"
    open "/Applications/$APP_DISPLAY_NAME.app"
fi

echo "==> Done: $APP_BUNDLE"
echo "    Bundle ID: $BUNDLE_ID"
if [[ "$NO_INSTALL" == "true" ]]; then
    echo "    (Not installed - use without --no-install to install)"
else
    echo "    Run with: open \"/Applications/$APP_DISPLAY_NAME.app\""
fi
