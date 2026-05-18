#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLE_DIR="$ROOT_DIR/apps/apple"
LITERTLM_SRC="${AILEEN_LITERTLM_SRC:-$ROOT_DIR/.build/google-ai-edge-LiteRT-LM}"
BUILD_TARGET=""

usage() {
  cat >&2 <<'USAGE'
usage: scripts/bootstrap_apple.sh [options]

Options:
  --litert-src PATH              LiteRT-LM checkout path. Default: .build/google-ai-edge-LiteRT-LM
  --litert-ref REF               LiteRT-LM tag or commit. Default: v0.10.1
  --build [simulator|device[:id]]
                                  Build after preparing the project. Default target: simulator.
  -h, --help                     Show this help.

The script prepares the Apple app from a clean checkout: Google AI Edge native
artifacts, generated Xcode project, and optionally an app build.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --litert-src)
      LITERTLM_SRC="${2:-}"
      shift 2
      ;;
    --litert-ref)
      export AILEEN_LITERTLM_REF="${2:-}"
      shift 2
      ;;
    --build)
      if [[ $# -ge 2 && "$2" != --* ]]; then
        BUILD_TARGET="$2"
        shift 2
      else
        BUILD_TARGET="simulator"
        shift
      fi
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$LITERTLM_SRC" ]]; then
  echo "--litert-src cannot be empty" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required" >&2
  exit 1
fi

if ! ruby -e 'require "xcodeproj"' >/dev/null 2>&1; then
  echo "Ruby gem xcodeproj is required. Install it with: gem install xcodeproj" >&2
  exit 1
fi

echo "Preparing Google AI Edge artifacts..."
"$APPLE_DIR/scripts/bootstrap_google_ai_edge_artifacts.sh" "$LITERTLM_SRC"

echo "Regenerating Xcode project..."
(
  cd "$APPLE_DIR"
  ruby scripts/generate_xcodeproj.rb
)

if [[ -n "$BUILD_TARGET" ]]; then
  echo "Building Apple app ($BUILD_TARGET)..."
  (
    cd "$APPLE_DIR"
    scripts/build_apple_quiet.sh "$BUILD_TARGET"
  )
fi

echo "Apple app bootstrap complete."
