#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
notifdex_smoke_dir="$(mktemp -d)"
trap 'cat "$notifdex_smoke_dir/stdout" "$notifdex_smoke_dir/stderr" 2>/dev/null || true; rm -rf "$notifdex_smoke_dir"' EXIT
open -n -W --stdout "$notifdex_smoke_dir/stdout" --stderr "$notifdex_smoke_dir/stderr" \
  "$PWD/dist/Notifdex.app" --args --smoke-test
/usr/bin/grep -q 'Smoke test: application did finish launching' "$notifdex_smoke_dir/stdout"
/usr/bin/grep -q 'Smoke test: real worker ready' "$notifdex_smoke_dir/stdout"
/usr/bin/grep -q 'Smoke test: worker stopped' "$notifdex_smoke_dir/stdout"
/usr/bin/grep -q 'Smoke test: window entered app switcher' "$notifdex_smoke_dir/stdout"
/usr/bin/grep -q 'Smoke test: closed window returned to menu bar' "$notifdex_smoke_dir/stdout"
