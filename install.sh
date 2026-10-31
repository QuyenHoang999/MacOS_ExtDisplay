#!/bin/zsh
#
# install.sh — Builds and installs ExtDisplayHost (macOS) and/or ExtDisplayClient (iOS/iPadOS)
#
# Usage:
#   ./install.sh            # Build & install macOS Host to /Applications & start in background
#   ./install.sh --dmg      # Build macOS Host + create dist/ExtDisplayHost.dmg
#   ./install.sh --client   # Build iOS/iPadOS Client -> dist/ExtDisplayClient.ipa (& install if device connected)
#   ./install.sh --android  # Build Android Client -> dist/ExtDisplayAndroid.apk (& install via adb if connected)
#   ./install.sh --all      # Build macOS Host (.dmg) + iOS/iPadOS Client (.ipa) + Android Client (.apk)
#

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${PROJECT_DIR}/dist"
MODE="${1:-host}"

build_host() {
  local create_dmg="${1:-false}"
  local derived_dir="/tmp/ExtDisplayHostBuild"
  local app_name="ExtDisplayHost.app"
  local install_path="/Applications/${app_name}"
  local launch_agent_plist="${HOME}/Library/LaunchAgents/com.QHpersonalteam.ExtDisplay.Host.plist"

  echo "==> Building ${app_name} (Release for macOS)..."
  rm -rf "${derived_dir}"
  xcodebuild \
    -project "${PROJECT_DIR}/Ext_Display.xcodeproj" \
    -scheme ExtDisplayHost \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "${derived_dir}" \
    build | tail -n 20

  local built_app="${derived_dir}/Build/Products/Release/${app_name}"
  if [[ ! -d "${built_app}" ]]; then
    echo "Error: Build product not found at ${built_app}" >&2
    exit 1
  fi

  echo "==> Stopping any running ExtDisplayHost instance..."
  killall -9 ExtDisplayHost 2>/dev/null || true

  echo "==> Installing to ${install_path}..."
  rm -rf "${install_path}"
  cp -R "${built_app}" "${install_path}"
  xattr -cr "${install_path}" 2>/dev/null || true

  local lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
  if [[ -x "${lsregister}" ]]; then
    "${lsregister}" -f -R -trusted "${install_path}" || true
  fi

  echo "==> Configuring background auto-start at Mac login..."
  mkdir -p "${HOME}/Library/LaunchAgents"
  cat > "${launch_agent_plist}" <<EOF
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
        <string>pgrep -x ExtDisplayHost &gt;/dev/null 2&gt;&amp;1 || /usr/bin/open -g -j -a '${install_path}' --args --background</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

  if [[ "${create_dmg}" == "true" ]]; then
    local staging_dir="/tmp/ExtDisplayDMGStaging"
    local dmg_path="${DIST_DIR}/ExtDisplayHost.dmg"
    echo "==> Creating distributable DMG at ${dmg_path}..."
    mkdir -p "${DIST_DIR}"
    rm -rf "${staging_dir}" "${dmg_path}"
    mkdir -p "${staging_dir}"
    cp -R "${install_path}" "${staging_dir}/${app_name}"
    ln -s /Applications "${staging_dir}/Applications"
    hdiutil create -volname "ExtDisplay Host" -srcfolder "${staging_dir}" -ov -format UDZO "${dmg_path}"
    rm -rf "${staging_dir}"
    echo "✅ Created macOS DMG: ${dmg_path}"
  fi

  rm -rf "${derived_dir}"

  echo "==> Starting ${app_name} in background..."
  open -g -j -a "${install_path}" --args --background
  echo "✅ Installed ${install_path} and started in the background."
}

build_client() {
  local derived_dir="/tmp/ExtDisplayClientBuild"
  local app_name="ExtDisplayClient.app"
  local ipa_staging="/tmp/ExtDisplayIPAStaging"
  local ipa_path="${DIST_DIR}/ExtDisplayClient.ipa"

  echo "==> Building ${app_name} (Release for iOS/iPadOS)..."
  rm -rf "${derived_dir}"
  xcodebuild \
    -project "${PROJECT_DIR}/Ext_Display.xcodeproj" \
    -scheme ExtDisplayClient \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "${derived_dir}" \
    -allowProvisioningUpdates \
    build | tail -n 20

  local built_app="${derived_dir}/Build/Products/Release-iphoneos/${app_name}"
  if [[ ! -d "${built_app}" ]]; then
    echo "Error: Client app not found at ${built_app}" >&2
    exit 1
  fi

  echo "==> Packaging ${ipa_path}..."
  mkdir -p "${DIST_DIR}"
  rm -rf "${ipa_staging}" "${ipa_path}"
  mkdir -p "${ipa_staging}/Payload"
  cp -R "${built_app}" "${ipa_staging}/Payload/${app_name}"
  (cd "${ipa_staging}" && zip -qry "${ipa_path}" Payload)
  rm -rf "${ipa_staging}"
  echo "✅ Created iOS/iPadOS IPA: ${ipa_path}"

  # If an iPad or iPhone is connected via USB, install directly onto the device
  local device_id
  device_id="$(xcrun xctrace list devices 2>/dev/null | awk '/^== Devices ==/{flag=1;next} /^==/{flag=0} flag && !/Mac/ && /\([0-9A-Fa-f-]+\)$/{match($0, /\(([0-9A-Fa-f-]+)\)$/); print substr($0, RSTART+1, RLENGTH-2); exit}' || true)"
  if [[ -n "${device_id}" ]]; then
    echo "==> Detected connected iOS/iPadOS device (${device_id}) — installing ${app_name}..."
    xcrun devicectl device install app --device "${device_id}" "${built_app}" || true
  else
    echo "ℹ️  To install onto your iPad/iPhone: plug it in via USB-C and run './install.sh --client' again (or drag ${ipa_path} into Apple Configurator / Finder)."
  fi

  rm -rf "${derived_dir}"
}

build_android() {
  local android_dir="${PROJECT_DIR}/ExtDisplayAndroid"
  local apk_out="${DIST_DIR}/ExtDisplayAndroid.apk"

  echo "==> Building ExtDisplayAndroid (Release APK)..."
  mkdir -p "${DIST_DIR}"
  (cd "${android_dir}" && ./gradlew assembleRelease)

  local built_apk="${android_dir}/app/build/outputs/apk/release/app-release.apk"
  if [[ ! -f "${built_apk}" ]]; then
    built_apk="$(find "${android_dir}/app/build/outputs/apk" -name "*.apk" | head -n 1 || true)"
  fi
  if [[ -z "${built_apk}" || ! -f "${built_apk}" ]]; then
    echo "Error: Built Android APK not found." >&2
    exit 1
  fi

  cp "${built_apk}" "${apk_out}"
  echo "✅ Created Android Release APK: ${apk_out}"

  local adb_bin="${HOME}/Library/Android/sdk/platform-tools/adb"
  if [[ ! -x "${adb_bin}" ]]; then
    adb_bin="$(command -v adb 2>/dev/null || true)"
  fi
  if [[ -n "${adb_bin}" && -x "${adb_bin}" ]]; then
    if "${adb_bin}" devices | grep -w "device" >/dev/null 2>&1; then
      echo "==> Installing ${apk_out} onto connected Android phone..."
      "${adb_bin}" install -r "${apk_out}" || true
    fi
  fi
}

case "${MODE}" in
  host)
    build_host "false"
    ;;
  --dmg)
    build_host "true"
    ;;
  --client)
    build_client
    ;;
  --android)
    build_android
    ;;
  --all)
    build_host "true"
    build_client
    build_android
    ;;
  *)
    echo "Usage: ./install.sh [--dmg | --client | --android | --all]" >&2
    exit 1
    ;;
esac
