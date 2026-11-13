#!/bin/bash
# Build iShot.app (Release) into build/iShot.app.
#   scripts/build-app.sh               → arm64 (host arch), ad-hoc signature
#   scripts/build-app.sh --universal   → arm64 + x86_64 (needs Xcode)
# Environment:
#   ISHOT_SIGN_IDENTITY  "Developer ID Application: …" to sign for distribution (default: ad-hoc "-")
#   ISHOT_SDK            SDK path for swift build (auto-detected with Command Line Tools only)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/build/iShot.app"
VERSION="0.1.0"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
IDENTITY="${ISHOT_SIGN_IDENTITY:--}"

UNIVERSAL=0
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=1

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
echo "Built $APP_DIR ($VERSION)"
