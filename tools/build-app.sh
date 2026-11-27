#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

notifdex_version="${NOTIFDEX_VERSION:-0.1.0}"
notifdex_build_number="${NOTIFDEX_BUILD_NUMBER:-1}"
notifdex_signing_identity="${NOTIFDEX_SIGNING_IDENTITY:-}"
notifdex_expected_team_id="${NOTIFDEX_EXPECTED_TEAM_ID:-}"
notifdex_provisioning_profile="${NOTIFDEX_PROVISIONING_PROFILE:-}"
notifdex_entitlements="${NOTIFDEX_ENTITLEMENTS:-Resources/NotifdexMac.entitlements}"

if [[ ! "$notifdex_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
    echo "Invalid NOTIFDEX_VERSION: $notifdex_version" >&2
    exit 1
fi

if [[ ! "$notifdex_build_number" =~ ^[0-9]+$ ]] || [[ "$notifdex_build_number" == "0" ]]; then
    echo "Invalid NOTIFDEX_BUILD_NUMBER (must be a positive integer): $notifdex_build_number" >&2
    exit 1
fi

if [[ "${NOTIFDEX_UNIVERSAL:-0}" == "1" ]]; then
    swift build -c release --arch arm64 --product Notifdex
    notifdex_arm_dir="$(swift build -c release --arch arm64 --show-bin-path)"
    swift build -c release --arch x86_64 --product Notifdex
    notifdex_intel_dir="$(swift build -c release --arch x86_64 --show-bin-path)"
    notifdex_bin_dir="$PWD/.build/notifdex-universal"
    mkdir -p "$notifdex_bin_dir"
    lipo -create "$notifdex_arm_dir/Notifdex" "$notifdex_intel_dir/Notifdex" -output "$notifdex_bin_dir/Notifdex"
else
    swift build -c release --product Notifdex
    notifdex_bin_dir="$(swift build -c release --show-bin-path)"
fi

notifdex_app_dir="$PWD/dist/Notifdex.app"
rm -rf "$notifdex_app_dir"
mkdir -p "$notifdex_app_dir/Contents/MacOS" "$notifdex_app_dir/Contents/Resources"
install -m 755 "$notifdex_bin_dir/Notifdex" "$notifdex_app_dir/Contents/MacOS/Notifdex"
cp Sources/NotifdexCore/*.sql "$notifdex_app_dir/Contents/Resources/"
cp -R templates "$notifdex_app_dir/Contents/Resources/"

if [[ -f Resources/Icons/AppIcon.png ]]; then
    cp Resources/Icons/AppIcon.png "$notifdex_app_dir/Contents/Resources/AppIcon.png"
    notifdex_iconset="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$notifdex_iconset"
    for sz in 16 32 128 256 512; do
        sips -z "$sz" "$sz" Resources/Icons/AppIcon.png --out "$notifdex_iconset/icon_${sz}x${sz}.png" >/dev/null
        sz2=$((sz * 2))
        sips -z "$sz2" "$sz2" Resources/Icons/AppIcon.png --out "$notifdex_iconset/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$notifdex_iconset" -o "$notifdex_app_dir/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$notifdex_iconset")"
fi

cat > "$notifdex_app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>Notifdex</string>
    <key>CFBundleDisplayName</key><string>Notifdex</string>
    <key>CFBundleIdentifier</key><string>com.notifdex.mac</string>
    <key>CFBundleExecutable</key><string>Notifdex</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${notifdex_version}</string>
    <key>CFBundleVersion</key><string>${notifdex_build_number}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

if [[ -n "$notifdex_signing_identity" ]]; then
    codesign_extra_args=()
    effective_entitlements=""
    if [[ -n "$notifdex_provisioning_profile" ]]; then
        if [[ ! -f "$notifdex_provisioning_profile" ]]; then
            echo "Provisioning profile not found: $notifdex_provisioning_profile" >&2
            exit 1
        fi
        if [[ ! -f "$notifdex_entitlements" ]]; then
            echo "Entitlements file not found: $notifdex_entitlements" >&2
            exit 1
        fi

        effective_entitlements="$(mktemp -t notifdex-entitlements).plist"
        profile_xml="$(mktemp -t notifdex-profile).plist"
        trap 'rm -f "${effective_entitlements:-}" "${profile_xml:-}"' EXIT
        security cms -D -i "$notifdex_provisioning_profile" > "$profile_xml"

        python3 - "$profile_xml" "$notifdex_entitlements" "$effective_entitlements" <<'PY'
import plistlib
import sys

profile_path, ent_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
profile = plistlib.loads(open(profile_path, "rb").read())
profile_ent = profile.get("Entitlements", {})
requested = plistlib.loads(open(ent_path, "rb").read())

req_app_id = requested.get("com.apple.application-identifier")
prof_app_id = profile_ent.get("com.apple.application-identifier")
if req_app_id and prof_app_id and prof_app_id != req_app_id and not prof_app_id.endswith(".*"):
    raise SystemExit(
        f"Provisioning profile app ID ({prof_app_id}) does not match entitlements ({req_app_id})"
    )

req_env = requested.get("com.apple.developer.icloud-container-environment")
prof_env = profile_ent.get("com.apple.developer.icloud-container-environment")
if req_env:
    allowed_envs = [prof_env] if isinstance(prof_env, str) else list(prof_env or [])
    if req_env not in allowed_envs:
        raise SystemExit(
            f"Provisioning profile does not authorize CloudKit environment '{req_env}' (profile allows: {allowed_envs})"
        )

req_containers = requested.get("com.apple.developer.icloud-container-identifiers") or []
prof_containers = profile_ent.get("com.apple.developer.icloud-container-identifiers")
if req_containers:
    allowed_containers = [prof_containers] if isinstance(prof_containers, str) else list(prof_containers or [])
    if "*" not in allowed_containers:
        missing = [c for c in req_containers if c not in allowed_containers]
        if missing:
            raise SystemExit(
                f"Provisioning profile missing CloudKit container(s): {missing} (profile allows: {allowed_containers})"
            )

# Automatically include macOS APNs entitlement if the provisioning profile explicitly grants it.
# macOS provisioning profiles use `com.apple.developer.aps-environment` (iOS uses `aps-environment`).
aps_label = "none"
for aps_key in ("com.apple.developer.aps-environment", "aps-environment"):
    prof_aps = profile_ent.get(aps_key)
    if isinstance(prof_aps, str) and prof_aps:
        if aps_key not in requested:
            requested[aps_key] = prof_aps
        aps_label = f"{aps_key}={requested[aps_key]}"
        break

with open(out_path, "wb") as f:
    plistlib.dump(requested, f, fmt=plistlib.FMT_XML)

print(
    f"Verified provisioning profile '{profile.get('Name', 'unknown')}': "
    f"app-id={prof_app_id}, icloud-env={req_env}, containers={req_containers}, "
    f"aps={aps_label}"
)
PY

        cp "$notifdex_provisioning_profile" "$notifdex_app_dir/Contents/embedded.provisionprofile"
        codesign_extra_args+=(--entitlements "$effective_entitlements")
        echo "Signing $notifdex_app_dir with CloudKit provisioning profile + entitlements"
    else
        echo "Signing $notifdex_app_dir with Developer ID identity (hardened runtime + timestamp)"
    fi
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$notifdex_signing_identity" \
        --identifier com.notifdex.mac \
        ${codesign_extra_args[@]+"${codesign_extra_args[@]}"} \
        "$notifdex_app_dir"
    codesign --verify --deep --strict --verbose=2 "$notifdex_app_dir"

    if [[ -n "$notifdex_expected_team_id" ]]; then
        designated_req="$(codesign -d -r - "$notifdex_app_dir" 2>&1)"
        if ! grep -Fq 'identifier "com.notifdex.mac"' <<<"$designated_req"; then
            echo "Designated requirement missing bundle identifier com.notifdex.mac" >&2
            echo "$designated_req" >&2
            exit 1
        fi
        if ! grep -Fq "subject.OU] = ${notifdex_expected_team_id}" <<<"$designated_req"; then
            echo "Designated requirement missing expected Team ID ${notifdex_expected_team_id}" >&2
            echo "$designated_req" >&2
            exit 1
        fi
    fi
else
    codesign --force --sign - --identifier com.notifdex.mac "$notifdex_app_dir"
    codesign --verify --deep --strict "$notifdex_app_dir"
fi

echo "Checking packaged SQLite resources and replay behavior"
"$notifdex_app_dir/Contents/MacOS/Notifdex" --self-check
echo "Built $notifdex_app_dir (version $notifdex_version, build $notifdex_build_number)"
