#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MonoAiBar"
APP_VERSION="0.0.1"
BUNDLE_ID="com.joaooliveira889.monoaibar"

APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

./scripts/build.sh

echo "==> Creating macOS bundle ${APP_DIR} for Apple Silicon (ARM64) and macOS 26+..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp ".build/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

cat << PLIST > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# A stable code signature is a hard requirement, not a nicety: the keychain records the signing
# identity of whichever app created or was granted access to an item. Ad-hoc signatures change
# their cdhash on every build, so every rebuild reads as a different app and macOS re-prompts for
# permission. Signing with a real certificate keeps one "Always Allow" valid forever.
SIGN_IDENTITY=""
for CANDIDATE in "Developer ID Application" "Apple Development"; do
    FOUND=$(security find-identity -v -p codesigning 2>/dev/null \
        | { grep "${CANDIDATE}" || true; } \
        | head -1 \
        | sed -E 's/.*\) ([A-F0-9]{40}) ".*/\1/')
    if [ -n "${FOUND}" ]; then
        SIGN_IDENTITY="${FOUND}"
        SIGN_LABEL="${CANDIDATE}"
        break
    fi
done

if [ -n "${SIGN_IDENTITY}" ]; then
    echo "==> Signing ${APP_DIR} with ${SIGN_LABEL} (${SIGN_IDENTITY}) and hardened runtime..."
    codesign --force \
        --sign "${SIGN_IDENTITY}" \
        --identifier "${BUNDLE_ID}" \
        --options runtime \
        --timestamp \
        "${APP_DIR}"
else
    echo "!!  No codesigning identity found; falling back to an ad-hoc signature."
    echo "!!  macOS will re-prompt for keychain access after every rebuild."
    codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP_DIR}"
fi

codesign --verify --strict --verbose=2 "${APP_DIR}"
echo "==> ${APP_DIR} v${APP_VERSION} created and signed."
