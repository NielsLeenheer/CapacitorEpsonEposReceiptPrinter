#!/usr/bin/env bash
#
# Re-read the shipped EULA before running — Epson revises it.
#
# Refresh the vendored Epson ePOS2 SDK binaries + EULA from the two Epson SDK
# ZIPs (iOS + Android). Usage:
#
#   scripts/update-epson-sdk.sh <ePOS_SDK_iOS_*.zip> <ePOS_SDK_Android_*.zip>
#
# What it vendors (D-P8 — binaries are COMMITTED, no fetch-at-install step):
#   iOS ZIP:
#     libepos2-static.xcframework   -> ios/Frameworks/libepos2.xcframework
#                                      (STATIC linkage; the `-static` suffix dropped)
#     PrivacyInfo.xcprivacy         -> ios/Frameworks/PrivacyInfo.xcprivacy
#     EULA.en.txt                   -> EPSON-EULA.en.txt   (repo root; §2.2 — the
#                                      EULA must accompany the distributed binaries)
#   Android ZIP:
#     ePOS2.jar                     -> android/libs/ePOS2.jar
#     {arm64-v8a,armeabi-v7a,x86_64}/libepos2.so
#                                   -> android/src/main/jniLibs/<abi>/libepos2.so
#     (x86 dropped; ePOSEasySelect NOT copied — unused)
#
# Prints the version folder names found inside each ZIP.

set -euo pipefail

if [[ $# -ne 2 ]]; then
	echo "Usage: $0 <ios-sdk.zip> <android-sdk.zip>" >&2
	exit 1
fi

IOS_ZIP="$1"
ANDROID_ZIP="$2"

for z in "${IOS_ZIP}" "${ANDROID_ZIP}"; do
	if [[ ! -f "${z}" ]]; then
		echo "ERROR: ZIP not found: ${z}" >&2
		exit 1
	fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Top-level folder inside a ZIP (e.g. ePOS_SDK_iOS_v2.37.0a), skipping any
# macOS __MACOSX sidecar.
top_folder() {
	(cd "$1" && ls -d */ 2>/dev/null | grep -v '^__MACOSX/' | head -n1 | sed 's#/$##')
}

# ---- iOS ----
IOS_WORK="${WORK}/ios"
mkdir -p "${IOS_WORK}"
unzip -q "${IOS_ZIP}" -d "${IOS_WORK}"
IOS_ROOT="$(top_folder "${IOS_WORK}")"
IOS_SRC="${IOS_WORK}/${IOS_ROOT}"

STATIC_FW="${IOS_SRC}/libepos2-static.xcframework"
if [[ ! -d "${STATIC_FW}" ]]; then
	echo "ERROR: libepos2-static.xcframework not found in ${IOS_ZIP}" >&2
	exit 1
fi

mkdir -p "${PLUGIN_DIR}/ios/Frameworks"
rm -rf "${PLUGIN_DIR}/ios/Frameworks/libepos2.xcframework"
cp -R "${STATIC_FW}" "${PLUGIN_DIR}/ios/Frameworks/libepos2.xcframework"
cp "${IOS_SRC}/PrivacyInfo.xcprivacy" "${PLUGIN_DIR}/ios/Frameworks/PrivacyInfo.xcprivacy"
cp "${IOS_SRC}/EULA.en.txt" "${PLUGIN_DIR}/EPSON-EULA.en.txt"

# ---- Android ----
AND_WORK="${WORK}/android"
mkdir -p "${AND_WORK}"
unzip -q "${ANDROID_ZIP}" -d "${AND_WORK}"
AND_ROOT="$(top_folder "${AND_WORK}")"
AND_SRC="${AND_WORK}/${AND_ROOT}"

if [[ ! -f "${AND_SRC}/ePOS2.jar" ]]; then
	echo "ERROR: ePOS2.jar not found in ${ANDROID_ZIP}" >&2
	exit 1
fi

mkdir -p "${PLUGIN_DIR}/android/libs"
cp "${AND_SRC}/ePOS2.jar" "${PLUGIN_DIR}/android/libs/ePOS2.jar"

for abi in arm64-v8a armeabi-v7a x86_64; do
	if [[ ! -f "${AND_SRC}/${abi}/libepos2.so" ]]; then
		echo "ERROR: ${abi}/libepos2.so not found in ${ANDROID_ZIP}" >&2
		exit 1
	fi
	mkdir -p "${PLUGIN_DIR}/android/src/main/jniLibs/${abi}"
	cp "${AND_SRC}/${abi}/libepos2.so" "${PLUGIN_DIR}/android/src/main/jniLibs/${abi}/libepos2.so"
done

echo "Vendored ePOS2 SDK refreshed:"
echo "  iOS SDK folder:     ${IOS_ROOT}"
echo "  Android SDK folder: ${AND_ROOT}"
echo
echo "Reminder: re-read EPSON-EULA.en.txt before shipping — Epson revises the license terms."
