#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mode="archive-only"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive-only)
            mode="archive-only"
            shift
            ;;
        --export-only)
            mode="export-only"
            shift
            ;;
        --upload)
            mode="upload"
            shift
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: bash tools/archive-ios-testflight.sh [--archive-only | --export-only | --upload]

Environment overrides:
  NOTIFDEX_IOS_VERSION            CFBundleShortVersionString / MARKETING_VERSION (default: 0.2.0)
  NOTIFDEX_IOS_BUILD_NUMBER       CFBundleVersion / CURRENT_PROJECT_VERSION (default: git rev-list --count HEAD)
  NOTIFDEX_IOS_OUTPUT_DIR         Output directory (default: dist/ios)
  APP_STORE_CONNECT_API_KEY_PATH  Optional .p8 path for headless xcodebuild auth
  APP_STORE_CONNECT_API_KEY_ID    Optional 10-char ASC Key ID
  APP_STORE_CONNECT_API_ISSUER_ID Optional ASC Issuer UUID
USAGE
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

version="${NOTIFDEX_IOS_VERSION:-0.2.0}"
build_number="${NOTIFDEX_IOS_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
output_dir="${NOTIFDEX_IOS_OUTPUT_DIR:-$PWD/dist/ios}"
archive_path="${output_dir}/NotifdexiOS.xcarchive"
export_dir="${output_dir}/export"
base_export_plist="$PWD/ios/ExportOptions-AppStore.plist"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid NOTIFDEX_IOS_VERSION (must be major.minor.patch): $version" >&2
    exit 1
fi
if [[ ! "$build_number" =~ ^[0-9]+$ ]] || [[ "$build_number" == "0" ]]; then
    echo "Invalid NOTIFDEX_IOS_BUILD_NUMBER (must be a positive integer): $build_number" >&2
    exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$output_dir"
rm -rf "$archive_path" "$export_dir"

auth_args=()
if [[ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]]; then
    if [[ -z "${APP_STORE_CONNECT_API_KEY_ID:-}" || -z "${APP_STORE_CONNECT_API_ISSUER_ID:-}" ]]; then
        echo "APP_STORE_CONNECT_API_KEY_ID and APP_STORE_CONNECT_API_ISSUER_ID are required when APP_STORE_CONNECT_API_KEY_PATH is set." >&2
        exit 1
    fi
    auth_args+=(
        -authenticationKeyPath "$APP_STORE_CONNECT_API_KEY_PATH"
        -authenticationKeyID "$APP_STORE_CONNECT_API_KEY_ID"
        -authenticationKeyIssuerID "$APP_STORE_CONNECT_API_ISSUER_ID"
    )
fi

echo "Archiving NotifdexiOS ${version} (${build_number}) -> ${archive_path}"
xcodebuild \
    -project ios/NotifdexiOS.xcodeproj \
    -scheme NotifdexiOS \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$archive_path" \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    -allowProvisioningUpdates \
    ${auth_args[@]+"${auth_args[@]}"} \
    archive

app_bundle="${archive_path}/Products/Applications/NotifdexiOS.app"
if [[ ! -d "$app_bundle" ]]; then
    echo "Expected archived app bundle not found: $app_bundle" >&2
    exit 1
fi

echo "Verifying archived NotifdexiOS.app metadata, privacy manifest, icon, and entitlements"
python3 - "$app_bundle" "$version" "$build_number" <<'PY'
import plistlib
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1])
expected_version = sys.argv[2]
expected_build = sys.argv[3]

info = plistlib.loads((app / "Info.plist").read_bytes())
assert info.get("CFBundleIdentifier") == "com.notifdex.ios", f"Unexpected bundle ID: {info.get('CFBundleIdentifier')}"
assert info.get("CFBundleShortVersionString") == expected_version, f"Version mismatch: {info.get('CFBundleShortVersionString')} != {expected_version}"
assert info.get("CFBundleVersion") == expected_build, f"Build mismatch: {info.get('CFBundleVersion')} != {expected_build}"
assert info.get("ITSAppUsesNonExemptEncryption") is False, "ITSAppUsesNonExemptEncryption must be false"
assert "remote-notification" in (info.get("UIBackgroundModes") or []), "Missing remote-notification background mode"
assert len(info.get("UISupportedInterfaceOrientations~ipad") or []) == 4, "Expected all 4 iPad orientations"

privacy_file = app / "PrivacyInfo.xcprivacy"
assert privacy_file.is_file(), "PrivacyInfo.xcprivacy missing from archived app bundle"
privacy = plistlib.loads(privacy_file.read_bytes())
assert privacy.get("NSPrivacyTracking") is False, "NSPrivacyTracking must be false"

assert (app / "Assets.car").is_file(), "Compiled Assets.car (AppIcon) missing from archived app bundle"

ent_out = subprocess.check_output(
    ["codesign", "-d", "--entitlements", ":-", str(app)],
    stderr=subprocess.DEVNULL,
    text=True,
)
assert "iCloud.com.notifdex.shared" in ent_out, "Archived app missing iCloud.com.notifdex.shared entitlement"
assert "aps-environment" in ent_out, "Archived app missing aps-environment entitlement"

print(
    f"Verified archive bundle: {info['CFBundleIdentifier']} "
    f"v{info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), "
    f"PrivacyInfo.xcprivacy present, Assets.car present, CloudKit + APNs entitlements embedded."
)
PY

if [[ "$mode" == "archive-only" ]]; then
    echo "Archive verified at: $archive_path"
    exit 0
fi

export_plist="$(mktemp -t notifdex-export-options).plist"
trap 'rm -f "$export_plist"' EXIT
cp "$base_export_plist" "$export_plist"
if [[ "$mode" == "upload" ]]; then
    plutil -replace destination -string upload "$export_plist"
    echo "Exporting and uploading NotifdexiOS ${version} (${build_number}) to App Store Connect / TestFlight"
else
    plutil -replace destination -string export "$export_plist"
    echo "Exporting App Store Connect IPA to ${export_dir}"
fi

xcodebuild \
    -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_plist" \
    -allowProvisioningUpdates \
    ${auth_args[@]+"${auth_args[@]}"}

if [[ "$mode" == "export-only" ]]; then
    ipa_path="${export_dir}/NotifdexiOS.ipa"
    if [[ -f "$ipa_path" ]]; then
        echo "Exported IPA: $ipa_path"
    fi
fi
