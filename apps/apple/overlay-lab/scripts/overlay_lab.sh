#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/aileen-overlay-lab"
BINARY="$BUILD_DIR/overlay-lab"

mkdir -p "$BUILD_DIR"

swiftc \
  -framework AppKit \
  -framework Vision \
  "$APPLE_ROOT/Aileen4DisasterRelief/Sources/AppModule/OverlayCore.swift" \
  "$APPLE_ROOT/overlay-lab/scripts/overlay_lab_support.swift" \
  "$APPLE_ROOT/overlay-lab/scripts/overlay_lab_main.swift" \
  -o "$BINARY"

exec "$BINARY" "$@"
