#!/bin/bash
# Build iShot.app (Release) into build/iShot.app.
#   scripts/build-app.sh               → arm64 (host arch)
#   scripts/build-app.sh --universal   → arm64 + x86_64 (needs Xcode)
#   scripts/build-app.sh --install     → also copy to /Applications/iShot.app and launch it
# Signing: uses the "iShot Local Signing" certificate (create it once with
# scripts/create-signing-cert.sh). A stable certificate keeps the Screen Recording permission
# across rebuilds; an ad-hoc signature changes on every build and macOS asks again each time.
# Environment:
#   ISHOT_SIGN_IDENTITY  signing identity (default: "iShot Local Signing" if present, else ad-hoc "-")
#   ISHOT_SDK            SDK path for swift build (auto-detected with Command Line Tools only)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/build/iShot.app"
VERSION="0.1.5"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
LOCAL_IDENTITY="iShot Local Signing"
INSTALL_DIR="/Applications/iShot.app"

UNIVERSAL=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --install) INSTALL=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [[ -n "${ISHOT_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$ISHOT_SIGN_IDENTITY"
elif security find-identity -v -p codesigning | grep -q "\"$LOCAL_IDENTITY\""; then
    IDENTITY="$LOCAL_IDENTITY"
else
    IDENTITY="-"
    echo "WARNING: signing ad-hoc. macOS will ask for Screen Recording again after every rebuild." >&2
    echo "         Run scripts/create-signing-cert.sh once to fix this." >&2
fi

# Command Line Tools without Xcode: the newest SDK may require SwiftUI macro
# plugins that only Xcode ships. Pick the newest SDK where State is not a macro.
if [[ -z "${ISHOT_SDK:-}" ]] && ! xcode-select -p | grep -q Xcode.app; then
    for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk | sort -rV); do
        iface="$sdk/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
        if [[ -f "$iface" ]] && ! grep -q 'public macro State()' "$iface"; then
            ISHOT_SDK="$sdk"
            break
        fi
    done
fi
[[ -n "${ISHOT_SDK:-}" ]] && export SDKROOT="$ISHOT_SDK" && echo "Using SDK $SDKROOT"

echo "==> Swift"
ARCH_FLAGS=()
[[ $UNIVERSAL == 1 ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build --package-path "$ROOT/app" -c release --product iShot ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build --package-path "$ROOT/app" -c release --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})/iShot"

echo "==> Bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/iShot"
[[ -f "$ROOT/app/Resources/AppIcon.icns" ]] && cp "$ROOT/app/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>iShot</string>
    <key>CFBundleIdentifier</key><string>com.local.ishot</string>
    <key>CFBundleName</key><string>iShot</string>
    <key>CFBundleDisplayName</key><string>iShot</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSScreenCaptureUsageDescription</key><string>iShot needs Screen Recording access to capture screenshots and record the screen.</string>
    <key>NSHumanReadableCopyright</key><string>iShot — menu-bar screenshot tool.</string>
</dict>
</plist>
EOF
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

echo "==> Sign ($IDENTITY)"
SIGN_ARGS=(--force --options runtime --sign "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$APP_DIR"
codesign --verify --strict --verbose=1 "$APP_DIR"
lipo -info "$APP_DIR/Contents/MacOS/iShot"
codesign -d -r- "$APP_DIR" 2>&1 | grep designated || true
echo "Built $APP_DIR ($VERSION)"

if [[ $INSTALL == 1 ]]; then
    echo "==> Install to $INSTALL_DIR"
    # Quit the running copy so the bundle can be replaced.
    osascript -e 'tell application id "com.local.ishot" to quit' >/dev/null 2>&1 || true
    pkill -x iShot 2>/dev/null || true
    sleep 1
    rm -rf "$INSTALL_DIR"
    ditto "$APP_DIR" "$INSTALL_DIR"
    open "$INSTALL_DIR"
    echo "Installed and launched $INSTALL_DIR"
fi
