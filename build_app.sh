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
SIGN_IDENTITY="HeadsUp Developer"

echo "==> Building Swift package ($CONFIG)..."
# Only the app product: HeadsUpChecks needs -enable-testing on HeadsUpKit,
# which is debug-only, so a plain `swift build -c release` cannot build it.
swift build -c "$CONFIG" --product "$APP_NAME"

BIN_PATH=$(swift build -c "$CONFIG" --show-bin-path)
EXEC_PATH="$BIN_PATH/$APP_NAME"

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

# Record where this bundle was built from (top-level Resources, where
# Bundle.main resource lookup finds it). The in-app updater uses it to know
# which checkout to `git pull` and rebuild.
pwd > "$APP_BUNDLE/Contents/Resources/source_path.txt"

# ============================================================================
# Info.plist generation: marketing version from the VERSION file (also what
# the in-app update check compares against the repo), plus an incrementing
# local build number (untracked, per machine).
# ============================================================================
SHORT_VERSION="1.0.0"
if [[ -f "VERSION" ]]; then
    SHORT_VERSION=$(tr -d '[:space:]' < VERSION)
fi

BUILD_NUMBER_FILE="build_number.txt"
if [[ -f "$BUILD_NUMBER_FILE" ]]; then
    BUILD_NUMBER=$(($(cat "$BUILD_NUMBER_FILE") + 1))
else
    BUILD_NUMBER=1
fi
echo "$BUILD_NUMBER" > "$BUILD_NUMBER_FILE"

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

codesign -f -s "$SIGN_IDENTITY" -i "$BUNDLE_ID" "$APP_BUNDLE"

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
