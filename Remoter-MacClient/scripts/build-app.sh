#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="RemoterClient"
BUNDLE_ID="com.remoter.client"
APP_VERSION="2.0.121"

BUILD_CONFIG="debug"
DO_INSTALL=0

for arg in "$@"; do
    case "$arg" in
        --release)
            BUILD_CONFIG="release"
            ;;
        --debug)
            BUILD_CONFIG="debug"
            ;;
        --install)
            DO_INSTALL=1
            ;;
        -h|--help)
            echo "Usage: $0 [--release|--debug] [--install]"
            echo "  --release   Build with swift build -c release (default: debug)"
            echo "  --install   Copy RemoterClient.app to /Applications"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

echo "==> Building ${APP_NAME} (${BUILD_CONFIG})..."
cd "${PROJECT_DIR}"
swift build -c "${BUILD_CONFIG}"

BIN_DIR="$(swift build -c "${BUILD_CONFIG}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${APP_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "Error: compiled binary not found at ${BIN_PATH}" >&2
    exit 1
fi

BUILD_DIR="${PROJECT_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Packaging ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

if [[ -f "${ROOT_DIR}/Resources/AppIcon.icns" ]]; then
    cp "${ROOT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

printf 'APPL????' > "${CONTENTS_DIR}/PkgInfo"

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Remoter Client</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Remoter Client</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

echo "==> Ad-hoc code signing ${APP_BUNDLE}..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Packaged successfully: ${APP_BUNDLE}"

if [[ "${DO_INSTALL}" -eq 1 ]]; then
    DEST="/Applications/${APP_NAME}.app"
    echo "==> Installing to ${DEST}..."
    rm -rf "${DEST}"
    cp -R "${APP_BUNDLE}" "${DEST}"
    echo "==> Installed: ${DEST}"
fi
