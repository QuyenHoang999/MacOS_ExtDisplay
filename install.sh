#!/bin/zsh
#
# install.sh — Builds and installs ExtDisplayHost.app into /Applications
# and optionally packages a distributable ExtDisplayHost.dmg installer.
#
# Usage:
#   ./install.sh          # Build Release app, install to /Applications & start in background
#   ./install.sh --dmg    # Also create dist/ExtDisplayHost.dmg for sharing / GitHub Releases
#

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DIR="/tmp/ExtDisplayInstallerBuild"
APP_NAME="ExtDisplayHost.app"
INSTALL_PATH="/Applications/${APP_NAME}"
LAUNCH_AGENT_PLIST="${HOME}/Library/LaunchAgents/com.QHpersonalteam.ExtDisplay.Host.plist"

echo "==> Building ${APP_NAME} (Release)..."
rm -rf "${DERIVED_DIR}"
xcodebuild \
  -project "${PROJECT_DIR}/Ext_Display.xcodeproj" \
  -scheme ExtDisplayHost \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED_DIR}" \
   build | tail -n 20

BUILT_APP="${DERIVED_DIR}/Build/Products/Release/${APP_NAME}"
if [[ ! -d "${BUILT_APP}" ]]; then
  echo "Error: Build product not found at ${BUILT_APP}" >&2
  exit 1
fi

echo "==> Stopping any running ExtDisplayHost instance..."
killall -9 ExtDisplayHost 2>/dev/null || true

echo "==> Installing to ${INSTALL_PATH}..."
rm -rf "${INSTALL_PATH}"
cp -R "${BUILT_APP}" "${INSTALL_PATH}"
xattr -cr "${INSTALL_PATH}" 2>/dev/null || true

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
if [[ -x "${LSREGISTER}" ]]; then
  "${LSREGISTER}" -f -R -trusted "${INSTALL_PATH}" || true
fi

echo "==> Configuring background auto-start at Mac login..."
mkdir -p "${HOME}/Library/LaunchAgents"
cat > "${LAUNCH_AGENT_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.QHpersonalteam.ExtDisplay.Host</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>pgrep -x ExtDisplayHost &gt;/dev/null 2&gt;&amp;1 || /usr/bin/open -g -j -a '${INSTALL_PATH}' --args --background</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

if [[ "${1:-}" == "--dmg" ]]; then
  DIST_DIR="${PROJECT_DIR}/dist"
  STAGING_DIR="/tmp/ExtDisplayDMGStaging"
  DMG_PATH="${DIST_DIR}/ExtDisplayHost.dmg"
  echo "==> Creating distributable DMG at ${DMG_PATH}..."
  mkdir -p "${DIST_DIR}"
  rm -rf "${STAGING_DIR}" "${DMG_PATH}"
  mkdir -p "${STAGING_DIR}"
  cp -R "${INSTALL_PATH}" "${STAGING_DIR}/${APP_NAME}"
  ln -s /Applications "${STAGING_DIR}/Applications"
  hdiutil create -volname "ExtDisplay Host" -srcfolder "${STAGING_DIR}" -ov -format UDZO "${DMG_PATH}"
  rm -rf "${STAGING_DIR}"
  echo "==> Created DMG: ${DMG_PATH}"
fi

rm -rf "${DERIVED_DIR}"

echo "==> Starting ${APP_NAME} in background..."
open -g -j -a "${INSTALL_PATH}" --args --background

echo "✅ Installed ${INSTALL_PATH} and started in the background (check the top menu bar icon)."
