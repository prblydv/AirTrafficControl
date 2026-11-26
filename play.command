#!/usr/bin/env bash
# Play Air Traffic Control: build (incremental) and launch the macOS game.
#
# Double-click this file in Finder, or in VS Code use Terminal > Run Task > Play.
#
# Options:
#   ./play.command              build if needed, then launch
#   ./play.command --skip-build launch the existing build
#   ./play.command --build-only build without launching
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIVED_DATA="$ROOT/build"
APP="$DERIVED_DATA/Build/Products/Debug/AirTrafficControl.app"

skip_build=0
build_only=0

for arg in "$@"; do
  case "$arg" in
    --skip-build) skip_build=1 ;;
    --build-only) build_only=1 ;;
    -h|--help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

if (( skip_build == 1 )); then
  if [[ ! -d "$APP" ]]; then
    echo "No build found. Run ./play.command without --skip-build." >&2
    exit 1
  fi
else
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found. Install Xcode or its command line tools." >&2
    exit 1
  fi

  echo "Building AirTrafficControl (Debug, macOS)…"
  xcodebuild \
    -project "$ROOT/AirTrafficControl.xcodeproj" \
    -scheme AirTrafficControl \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    -quiet \
    build
fi

if (( build_only == 1 )); then
  echo "Built $APP"
  exit 0
fi

echo "Launching AirTrafficControl…"
open "$APP"
