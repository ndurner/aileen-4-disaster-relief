#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <simulator|device[:destination-id]>" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Aileen4DisasterRelief.xcodeproj"
SCHEME="Aileen4DisasterRelief"
DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode-derived-data"
LOG_DIR="$ROOT_DIR/.build/logs"

mkdir -p "$DERIVED_DATA_PATH" "$LOG_DIR"

TARGET="$1"
BUILD_LOG="$LOG_DIR/xcodebuild-${TARGET//:/-}.log"

case "$TARGET" in
  simulator)
    DESTINATION="generic/platform=iOS Simulator"
    EXTRA_ARGS=()
    ;;
  device:*)
    DEVICE_ID="${TARGET#device:}"
    DESTINATION="id=$DEVICE_ID"
    EXTRA_ARGS=(-allowProvisioningUpdates)
    ;;
  device)
    DESTINATION="generic/platform=iOS"
    EXTRA_ARGS=(-allowProvisioningUpdates)
    ;;
  *)
    echo "unknown target: $TARGET" >&2
    exit 1
    ;;
esac

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination "$DESTINATION" \
  "${EXTRA_ARGS[@]}" \
  -quiet \
  build \
  >"$BUILD_LOG" 2>&1

echo "build succeeded"
echo "$BUILD_LOG"
