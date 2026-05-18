#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THIRD_PARTY_DIR="$ROOT_DIR/ThirdParty/GoogleAIEdge"
LITERTLM_SRC="${1:-}"
LITERTLM_REPO="${AILEEN_LITERTLM_REPO:-https://github.com/google-ai-edge/LiteRT-LM.git}"
LITERTLM_REF="${AILEEN_LITERTLM_REF:-v0.10.1}"

if [[ -z "$LITERTLM_SRC" ]]; then
  echo "usage: $0 /path/to/google-ai-edge-LiteRT-LM" >&2
  echo "If the LiteRT-LM path does not exist, the script clones $LITERTLM_REPO and checks out AILEEN_LITERTLM_REF (default: $LITERTLM_REF)." >&2
  exit 1
fi

if [[ ! -e "$LITERTLM_SRC" ]]; then
  echo "Cloning LiteRT-LM $LITERTLM_REF into $LITERTLM_SRC..."
  mkdir -p "$(dirname "$LITERTLM_SRC")"
  git clone "$LITERTLM_REPO" "$LITERTLM_SRC" >/dev/null
  git -C "$LITERTLM_SRC" checkout "$LITERTLM_REF" >/dev/null
fi

if [[ ! -f "$LITERTLM_SRC/c/engine.h" ]]; then
  echo "Expected a LiteRT-LM checkout at: $LITERTLM_SRC" >&2
  exit 1
fi

if ! command -v bazel >/dev/null 2>&1 && ! command -v bazelisk >/dev/null 2>&1; then
  echo "bazel or bazelisk is required to regenerate LiteRTLM.xcframework" >&2
  exit 1
fi

BAZEL_BIN="$(command -v bazelisk || command -v bazel)"
mkdir -p "$THIRD_PARTY_DIR"

echo "Building LiteRTLM.xcframework from official LiteRT-LM checkout..."
(
  cd "$LITERTLM_SRC"
  "$BAZEL_BIN" build --config=ios_arm64 //c:engine_xcframework >/dev/null
)

ENGINE_XCFRAMEWORK="$(find "$LITERTLM_SRC/bazel-bin" -path '*engine_xcframework.xcframework' | head -n 1)"
if [[ -z "$ENGINE_XCFRAMEWORK" ]]; then
  echo "Failed to locate built engine_xcframework.xcframework in bazel-bin" >&2
  exit 1
fi

rm -rf "$THIRD_PARTY_DIR/LiteRTLM.xcframework"
cp -R "$ENGINE_XCFRAMEWORK" "$THIRD_PARTY_DIR/LiteRTLM.xcframework"

copy_constraint_provider() {
  local platform_dir="$1"
  local output_dir="$2"
  local dylib_path="$LITERTLM_SRC/prebuilt/$platform_dir/libGemmaModelConstraintProvider.dylib"
  if [[ ! -f "$dylib_path" ]]; then
    echo "Missing official prebuilt: $dylib_path" >&2
    exit 1
  fi
  mkdir -p "$output_dir/Headers"
  cp "$dylib_path" "$output_dir/libGemmaModelConstraintProvider.dylib"
}

echo "Rebuilding a minimal GemmaModelConstraintProvider.xcframework from LiteRT-LM checkout prebuilts..."
rm -rf "$THIRD_PARTY_DIR/GemmaModelConstraintProvider.xcframework"
mkdir -p \
  "$THIRD_PARTY_DIR/GemmaModelConstraintProvider.xcframework/ios-arm64" \
  "$THIRD_PARTY_DIR/GemmaModelConstraintProvider.xcframework/ios-arm64-simulator"
copy_constraint_provider ios_arm64 "$THIRD_PARTY_DIR/GemmaModelConstraintProvider.xcframework/ios-arm64"
copy_constraint_provider ios_sim_arm64 "$THIRD_PARTY_DIR/GemmaModelConstraintProvider.xcframework/ios-arm64-simulator"

cat > "$THIRD_PARTY_DIR/GemmaModelConstraintProvider.xcframework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AvailableLibraries</key>
  <array>
    <dict>
      <key>BinaryPath</key>
      <string>libGemmaModelConstraintProvider.dylib</string>
      <key>HeadersPath</key>
      <string>Headers</string>
      <key>LibraryIdentifier</key>
      <string>ios-arm64-simulator</string>
      <key>LibraryPath</key>
      <string>libGemmaModelConstraintProvider.dylib</string>
      <key>SupportedArchitectures</key>
      <array><string>arm64</string></array>
      <key>SupportedPlatform</key>
      <string>ios</string>
      <key>SupportedPlatformVariant</key>
      <string>simulator</string>
    </dict>
    <dict>
      <key>BinaryPath</key>
      <string>libGemmaModelConstraintProvider.dylib</string>
      <key>HeadersPath</key>
      <string>Headers</string>
      <key>LibraryIdentifier</key>
      <string>ios-arm64</string>
      <key>LibraryPath</key>
      <string>libGemmaModelConstraintProvider.dylib</string>
      <key>SupportedArchitectures</key>
      <array><string>arm64</string></array>
      <key>SupportedPlatform</key>
      <string>ios</string>
    </dict>
  </array>
  <key>CFBundlePackageType</key>
  <string>XFWK</string>
  <key>XCFrameworkFormatVersion</key>
  <string>1.0</string>
</dict>
</plist>
PLIST

echo "Done. Regenerated Google AI Edge artifacts under:"
echo "  $THIRD_PARTY_DIR"
