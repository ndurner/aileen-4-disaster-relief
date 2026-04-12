#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <device-id> <bundle-id> <model-source> [<model-source> ...]" >&2
  exit 1
fi

DEVICE_ID="$1"
BUNDLE_ID="$2"
shift 2
MODEL_MANIFEST_NAME=".codex-model-manifest.txt"

cleanup() {
  [[ -n "${FILTERED_ROOT:-}" ]] && rm -rf "$FILTERED_ROOT"
  [[ -n "${CHECK_ROOT:-}" ]] && rm -rf "$CHECK_ROOT"
}
trap cleanup EXIT

FILTERED_ROOT="$(mktemp -d)"
CHECK_ROOT="$(mktemp -d)"

require_source() {
  local source_path="$1"
  if [[ ! -e "$source_path" ]]; then
    echo "Missing required model source: $source_path" >&2
    exit 1
  fi
}

prepare_filtered_directory() {
  local source_directory="$1"
  local filtered_directory="$2"
  python3 - "$source_directory" "$filtered_directory" <<'PY'
from pathlib import Path
import os
import sys

source_dir = Path(sys.argv[1])
filtered_dir = Path(sys.argv[2])

def should_include(path: Path) -> bool:
    if path.name.startswith("."):
        return False
    if not path.is_file():
        return False
    if path.name.endswith(".partial"):
        return False
    if ".part" in path.name:
        return False
    return True

for child in sorted(source_dir.iterdir()):
    if not should_include(child):
        continue
    os.link(child, filtered_dir / child.name)
PY
}

inject_directory() {
  local source_directory="$1"
  local directory_name
  directory_name="$(basename "$source_directory")"
  local filtered_directory="$FILTERED_ROOT/$directory_name"
  local local_manifest="$FILTERED_ROOT/$directory_name.$MODEL_MANIFEST_NAME"
  local remote_manifest="$CHECK_ROOT/$directory_name.$MODEL_MANIFEST_NAME"

  mkdir -p "$filtered_directory"
  prepare_filtered_directory "$source_directory" "$filtered_directory"
  find "$filtered_directory" -maxdepth 1 -type f -exec stat -f '%N\t%z' {} \; | sort > "$local_manifest"

  if xcrun devicectl device copy from \
    --device "$DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source "Library/Application Support/Models/$directory_name/$MODEL_MANIFEST_NAME" \
    --destination "$remote_manifest" \
    >/dev/null 2>&1 && cmp -s "$local_manifest" "$remote_manifest"
  then
    echo "Reusing injected $directory_name"
    return
  fi

  echo "Injecting directory $directory_name ..."
  while IFS= read -r source_path; do
    [[ -n "$source_path" ]] || continue
    xcrun devicectl device copy to \
      --device "$DEVICE_ID" \
      --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_ID" \
      --source "$source_path" \
      --destination "Library/Application Support/Models/$directory_name/$(basename "$source_path")"
  done < <(find "$filtered_directory" -maxdepth 1 -type f | sort)

  xcrun devicectl device copy to \
    --device "$DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source "$local_manifest" \
    --destination "Library/Application Support/Models/$directory_name/$MODEL_MANIFEST_NAME"
}

inject_file() {
  local source_file="$1"
  local file_name
  file_name="$(basename "$source_file")"
  local local_manifest="$FILTERED_ROOT/$file_name.$MODEL_MANIFEST_NAME"
  local remote_manifest="$CHECK_ROOT/$file_name.$MODEL_MANIFEST_NAME"

  stat -f '%N\t%z' "$source_file" > "$local_manifest"

  if xcrun devicectl device copy from \
    --device "$DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source "Library/Application Support/Models/$file_name.$MODEL_MANIFEST_NAME" \
    --destination "$remote_manifest" \
    >/dev/null 2>&1 && cmp -s "$local_manifest" "$remote_manifest"
  then
    echo "Reusing injected $file_name"
    return
  fi

  echo "Injecting file $file_name ..."
  xcrun devicectl device copy to \
    --device "$DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source "$source_file" \
    --destination "Library/Application Support/Models/$file_name"
  xcrun devicectl device copy to \
    --device "$DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source "$local_manifest" \
    --destination "Library/Application Support/Models/$file_name.$MODEL_MANIFEST_NAME"
}

for source_path in "$@"; do
  require_source "$source_path"
  if [[ -d "$source_path" ]]; then
    inject_directory "$source_path"
  else
    inject_file "$source_path"
  fi
done

echo "Injection complete."
