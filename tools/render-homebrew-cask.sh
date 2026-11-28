#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 <version> <sha256> [output-path]" >&2
    exit 1
fi

version="$1"
sha256="$2"
output_path="${3:-}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
    echo "Invalid version: $version" >&2
    exit 1
fi

if [[ ! "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Invalid SHA-256 hex digest: $sha256" >&2
    exit 1
fi

render() {
    cat <<EOF
cask "notifdex" do
  version "${version}"
  sha256 "${sha256}"

  url "https://github.com/notifdex/notifdex/releases/download/v#{version}/Notifdex-#{version}-macOS-universal.zip"
  name "Notifdex"
  desc "Local macOS notification inbox and people notebook"
  homepage "https://notifdex.com/"

  depends_on macos: :sonoma

  app "Notifdex.app"

  uninstall quit: "com.notifdex.mac"

  zap trash: [
    "~/Library/Application Support/Notifdex",
    "~/Library/Preferences/com.notifdex.mac.plist",
  ]

  caveats <<~EOS
    Open Notifdex from Applications or Spotlight to launch App Center (or use the
    menu bar icon anytime) and grant Accessibility access in:
    System Settings -> Privacy & Security -> Accessibility.

    Closing App Center keeps notification capture running in the background; click
    the Dock icon or press Cmd-Q to reopen or quit.

    For forwarded iPhone notifications, macOS 15 (Sequoia) and iOS 18 or later
    are required with iPhone Mirroring paired and "Allow notifications from iPhone"
    enabled in macOS System Settings.
  EOS
end
EOF
}

if [[ -n "$output_path" ]]; then
    mkdir -p "$(dirname "$output_path")"
    render > "$output_path"
else
    render
fi
