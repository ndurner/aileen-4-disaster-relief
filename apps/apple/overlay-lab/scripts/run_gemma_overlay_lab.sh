#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE_ID="de.ndurner.Aileen4DisasterRelief"
BUILD_SCRIPT="$APPLE_ROOT/scripts/build_apple_quiet.sh"
OVERLAY_LAB_SCRIPT="$APPLE_ROOT/overlay-lab/scripts/overlay_lab.sh"
APP_PATH="$APPLE_ROOT/.build/xcode-derived-data/Build/Products/Debug-iphonesimulator/Aileen4DisasterRelief.app"

choose_model_path() {
  local candidates=(
    "${AILEEN_GEMMA_VISUAL_MODEL:-}"
    "$HOME/dev/gemma4-tests2/.model-cache-stash/gemma-4-E2B-it.litertlm"
    "$HOME/dev/gemma4-tests/.model-cache-stash/gemma-4-E2B-it.litertlm"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "Unable to locate gemma-4-E2B-it.litertlm. Set AILEEN_GEMMA_VISUAL_MODEL." >&2
  exit 1
}

choose_device() {
  local booted
  booted="$(xcrun simctl list devices booted | grep -Eo '[A-F0-9-]{36}' | head -1 || true)"
  if [[ -n "$booted" ]]; then
    printf '%s\n' "$booted"
    return 0
  fi

  local fallback
  fallback="$(xcrun simctl list devices available | grep 'iPhone 17 Pro' | grep 'Shutdown' | grep -Eo '[A-F0-9-]{36}' | head -1 || true)"
  if [[ -z "$fallback" ]]; then
    echo "Unable to find a suitable simulator." >&2
    exit 1
  fi

  xcrun simctl boot "$fallback" >/dev/null
  xcrun simctl bootstatus "$fallback" -b >&2
  printf '%s\n' "$fallback"
}

stage_model() {
  local source_path="$1"
  local destination_path="$2"

  mkdir -p "$(dirname "$destination_path")"
  if [[ -f "$destination_path" ]]; then
    local source_size dest_size
    source_size="$(stat -f '%z' "$source_path")"
    dest_size="$(stat -f '%z' "$destination_path")"
    if [[ "$source_size" == "$dest_size" ]]; then
      return 0
    fi
    rm -f "$destination_path"
  fi

  if ! cp -c "$source_path" "$destination_path" 2>/dev/null; then
    cp "$source_path" "$destination_path"
  fi
}

main() {
  local model_path
  model_path="$(choose_model_path)"

  local device_id
  device_id="$(choose_device)"

  local output_root_base="${AILEEN_GEMMA_LAB_OUT:-/tmp/aileen-gemma-overlay-runs}"
  local timestamp
  timestamp="$(date '+%Y%m%d-%H%M%S')"
  local output_root="$output_root_base/$timestamp"
  mkdir -p "$output_root"

  local inputs=("$@")
  if [[ "${#inputs[@]}" -eq 0 ]]; then
    inputs=(/tmp/test-imgs/*)
  fi

  local existing_inputs=()
  local path
  for path in "${inputs[@]}"; do
    [[ -f "$path" ]] || continue
    existing_inputs+=("$path")
  done
  if [[ "${#existing_inputs[@]}" -eq 0 ]]; then
    echo "No input images found." >&2
    exit 1
  fi

  "$BUILD_SCRIPT" simulator >/dev/null
  xcrun simctl install "$device_id" "$APP_PATH" >/dev/null

  local data_container
  data_container="$(xcrun simctl get_app_container "$device_id" "$BUNDLE_ID" data)"
  local automation_root="$data_container/Documents/OverlayAutomation"
  local input_root="$automation_root/inputs"
  local result_root_rel="Documents/OverlayAutomation/results"
  local result_root="$data_container/$result_root_rel"
  local config_path="$automation_root/config.json"
  local model_destination="$data_container/Library/Application Support/Models/gemma-4-E2B-it.litertlm"

  rm -rf "$automation_root"
  mkdir -p "$input_root" "$result_root"

  local copied_inputs=()
  for path in "${existing_inputs[@]}"; do
    local target="$input_root/$(basename "$path")"
    cp "$path" "$target"
    local sidecar
    for sidecar in \
      "${path%.*}.txt" \
      "${path%.*}.briefing.txt" \
      "$(dirname "$path")/background_briefing.txt" \
      "$(dirname "$path")/briefing.txt"; do
      if [[ -f "$sidecar" ]]; then
        cp "$sidecar" "$input_root/$(basename "$sidecar")"
      fi
    done
    copied_inputs+=("$target")
  done

  stage_model "$model_path" "$model_destination"

  python3 - "$config_path" "${copied_inputs[@]}" <<'PY'
import json
import os
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
inputs = [Path(p) for p in sys.argv[2:]]

def read_text(path):
    try:
        return path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return ""


def sidecar_text(input_path, suffix):
    candidates = [
        input_path.with_suffix(suffix),
        input_path.with_name(f"{input_path.stem}{suffix}"),
    ]
    for candidate in candidates:
        text = read_text(candidate)
        if text:
            return text
    return ""


default_background = ""
for candidate_name in ("background_briefing.txt", "briefing.txt"):
    candidate_text = read_text(config_path.parent / "inputs" / candidate_name)
    if candidate_text:
        default_background = candidate_text
        break

global_background = os.environ.get("AILEEN_GEMMA_BACKGROUND")
global_story = os.environ.get("AILEEN_GEMMA_STORY")
allowed_suffixes = {
    item.strip()
    for item in os.environ.get("AILEEN_GEMMA_SCENARIOS", "").split(",")
    if item.strip()
}
enable_review = os.environ.get("AILEEN_GEMMA_ENABLE_REVIEW", "1").strip().lower() not in {"0", "false", "off", "no"}
post_review_mode = os.environ.get("AILEEN_GEMMA_POST_REVIEW_MODE", "result_only_forced_move").strip()
thinking_values_raw = os.environ.get("AILEEN_GEMMA_THINKING_MODES", "off,on")
thinking_values = []
for item in thinking_values_raw.split(","):
    normalized = item.strip().lower()
    if normalized in {"off", "false", "0"}:
        thinking_values.append((False, "think-off"))
    elif normalized in {"on", "true", "1"}:
        thinking_values.append((True, "think-on"))

if not thinking_values:
    thinking_values = [(False, "think-off"), (True, "think-on")]

scenario_templates = [
    {
        "suffix": "baseline",
        "promptAddendum": (
            "If you add text, prefer a single purposeful overlay. "
            "Avoid generic top-of-frame banners."
        ),
        "protectedRegionProvider": "none",
        "preOverlayAnalysisProvider": "none",
        "preOverlayAnalysisEnableThinking": False,
        "reuseGemmaEngine": False,
        "preOverlayGuidanceMode": "slot",
        "useLayoutGuideProtectedRegions": False,
        "reviewPass": {
            "enabled": True,
            "enableThinking": True,
            "rerunOnFailure": False,
            "reviewPromptAddendum": (
                "Score placement, style, and copy strictly. "
                "Reject banner-like overlays, overly generic copy, or overlays that sit too high."
            ),
        },
    },
    {
        "suffix": "normalized-measured",
        "promptAddendum": (
            "Use at most one overlay. Prefer the normalized overlay hints instead of raw width and height guesses. "
            "Choose style from the source frame. For a subject-dominant frame, prefer sticker with top_fraction between 0.20 and 0.32, max_width_fraction between 0.42 and 0.68, target_line_count 2, and horizontal_anchor center. "
            "For a clean negative-space frame, prefer caption with top_fraction between 0.46 and 0.58, max_width_fraction between 0.40 and 0.72, and target_line_count 1 or 2. "
            "Use headline only when the text can stay on one line and remain highly legible without a box. "
            "Leave raw x, y, width, and height unset unless you need a deliberate slot override."
        ),
        "protectedRegionProvider": "none",
        "preOverlayAnalysisProvider": "none",
        "preOverlayAnalysisEnableThinking": False,
        "reuseGemmaEngine": False,
        "preOverlayGuidanceMode": "slot",
        "useLayoutGuideProtectedRegions": False,
        "reviewPass": {
            "enabled": True,
            "enableThinking": True,
            "rerunOnFailure": False,
            "reviewPromptAddendum": (
                "Reward normalized placement that lands in a current-looking band and has non-uniform measured width."
            ),
        },
    },
    {
        "suffix": "slot-anchored",
        "promptAddendum": (
            "Use at most one overlay. Inspect the source frame and identify one clean free slot where text can live without covering the main subject. "
            "Describe that free slot with x, y, width, and height in the rendered canvas, then place the overlay inside it using horizontal_anchor center and vertical_anchor bottom. "
            "Use target_line_count so the renderer measures the final width from the text. "
            "Prefer sticker for busy subject-dominant frames and caption only for genuine negative space. "
            "Do not assume the final overlay should fill the full slot."
        ),
        "protectedRegionProvider": "none",
        "preOverlayAnalysisProvider": "none",
        "preOverlayAnalysisEnableThinking": False,
        "reuseGemmaEngine": False,
        "preOverlayGuidanceMode": "slot",
        "useLayoutGuideProtectedRegions": False,
        "reviewPass": {
            "enabled": True,
            "enableThinking": True,
            "rerunOnFailure": False,
            "reviewPromptAddendum": (
                "Reward slot selection that clearly avoids the subject and lets the measured overlay sit neatly at the bottom of the slot."
            ),
        },
    },
    {
        "suffix": "apple-protected",
        "promptAddendum": (
            "Use at most one overlay. Prefer the normalized overlay hints instead of hard-coding the final box. "
            "Keep the overlay comfortably away from the main subject. "
            "Prefer sticker for a busy subject-dominant frame and caption only when the frame has real open scenery."
        ),
        "protectedRegionProvider": "apple_vision",
        "preOverlayAnalysisProvider": "apple_vision",
        "preOverlayAnalysisEnableThinking": False,
        "reuseGemmaEngine": False,
        "preOverlayGuidanceMode": "slot",
        "useLayoutGuideProtectedRegions": False,
        "reviewPass": {
            "enabled": True,
            "enableThinking": True,
            "rerunOnFailure": False,
            "reviewPromptAddendum": (
                "This approach uses Apple Vision only as a benchmark comparator. "
                "Judge the actual render, not the intent."
            ),
        },
    },
    {
        "suffix": "gemma-layout-guided",
        "promptAddendum": (
            "Use at most one overlay. If the prompt includes a pre-analysis subject box or preferred slot, treat that as high-priority visual guidance. "
            "Keep the overlay completely outside the subject keep-clear box. "
            "If a preferred slot is given, use slot placement with the suggested anchors and let the renderer measure the final box from the text. "
            "Prefer sticker for busy subject-dominant frames and caption only for genuine negative space."
        ),
        "protectedRegionProvider": "none",
        "preOverlayAnalysisProvider": "gemma_vision",
        "preOverlayAnalysisEnableThinking": True,
        "reuseGemmaEngine": True,
        "preOverlayGuidanceMode": "slot",
        "useLayoutGuideProtectedRegions": False,
        "reviewPass": {
            "enabled": True,
            "enableThinking": True,
            "rerunOnFailure": False,
            "reviewPromptAddendum": (
                "This approach uses Gemma visual analysis before generation. "
                "Reward results that actually respect the guided slot and keep-clear subject box."
            ),
        },
    },
    {
        "suffix": "gemma-band-guided",
        "promptAddendum": (
            "Use at most one overlay. If the prompt includes a pre-analysis subject box or free-space region, treat it as coarse visual guidance rather than a final text box. "
            "Keep the overlay completely outside the subject keep-clear box. "
            "Prefer normalized hints, anchors, and measured sizing over raw x, y, width, and height. "
            "Use the free-space region mainly to choose side, band, and width ceiling. "
            "Prefer sticker for busy subject-dominant frames and caption only for genuine negative space."
        ),
        "protectedRegionProvider": "none",
        "preOverlayAnalysisProvider": "gemma_vision",
        "preOverlayAnalysisEnableThinking": True,
        "reuseGemmaEngine": True,
        "preOverlayGuidanceMode": "band",
        "useLayoutGuideProtectedRegions": False,
        "reviewPass": {
            "enabled": True,
            "enableThinking": True,
            "rerunOnFailure": False,
            "reviewPromptAddendum": (
                "This approach uses Gemma visual analysis to suggest coarse free-space guidance. "
                "Reward outputs that avoid the subject and let the renderer shape the final overlay naturally."
            ),
        },
    },
    {
        "suffix": "gemma-band-guarded",
        "promptAddendum": (
            "Use at most one overlay. If the prompt includes a pre-analysis subject box or free-space patch, treat it as coarse visual guidance rather than a final text box. "
            "Keep the overlay completely outside the subject keep-clear box. "
            "Prefer normalized hints, anchors, and measured sizing over raw x, y, width, and height. "
            "Use the free-space patch mainly to choose side, band, and width ceiling. "
            "Assume the renderer will actively push the overlay away from the subject if your first placement still grazes it. "
            "Prefer sticker for busy subject-dominant frames and caption only for genuine negative space."
        ),
        "protectedRegionProvider": "none",
        "preOverlayAnalysisProvider": "gemma_vision",
        "preOverlayAnalysisEnableThinking": True,
        "reuseGemmaEngine": True,
        "preOverlayGuidanceMode": "band",
        "useLayoutGuideProtectedRegions": True,
        "reviewPass": {
            "enabled": True,
            "enableThinking": True,
            "rerunOnFailure": False,
            "reviewPromptAddendum": (
                "This approach uses Gemma visual analysis plus a renderer keep-clear guard. "
                "Reward outputs that stay off the subject even when the model's first guess is imperfect."
            ),
        },
    },
]

if allowed_suffixes:
    scenario_templates = [
        template for template in scenario_templates
        if template["suffix"] in allowed_suffixes
    ]

scenarios = []
for input_path in inputs:
    relative_path = f"Documents/OverlayAutomation/inputs/{input_path.name}"
    stem = input_path.stem
    story = global_story if global_story is not None else sidecar_text(input_path, ".txt")
    background = (
        global_background
        if global_background is not None
        else sidecar_text(input_path, ".briefing.txt") or default_background
    )
    for template in scenario_templates:
        for enable_thinking, thinking_suffix in thinking_values:
            scenarios.append(
                {
                    "name": f"{stem}-{template['suffix']}-{thinking_suffix}",
                    "assetPaths": [relative_path],
                    "backgroundBriefing": background,
                    "story": story,
                    "promptAddendum": template["promptAddendum"],
                    "outputKind": "image",
                    "model": "gemma-4-E2B-it.litertlm",
                    "modelSource": "injected",
                    "enableThinking": enable_thinking,
                    "protectedRegionProvider": template["protectedRegionProvider"],
                    "preOverlayAnalysisProvider": template["preOverlayAnalysisProvider"],
                    "preOverlayAnalysisEnableThinking": template["preOverlayAnalysisEnableThinking"],
                    "reuseGemmaEngine": template["reuseGemmaEngine"],
                    "preOverlayGuidanceMode": template["preOverlayGuidanceMode"],
                    "useLayoutGuideProtectedRegions": template["useLayoutGuideProtectedRegions"],
                    "postReviewMode": post_review_mode,
                    "reviewPass": (
                        template["reviewPass"]
                        if enable_review
                        else {
                            "enabled": False,
                            "enableThinking": True,
                            "rerunOnFailure": False,
                            "reviewPromptAddendum": "",
                        }
                    ),
                }
            )

config = {
    "outputDirectory": "Documents/OverlayAutomation/results",
    "scenarios": scenarios,
}

config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
PY

  local launch_log="$output_root/simulator.log"
  : >"$launch_log"
  local launch_env=(
    "SIMCTL_CHILD_AILEEN_AUTOMATION_CONFIG_PATH=Documents/OverlayAutomation/config.json"
  )
  local forwarded_key
  for forwarded_key in \
    GEMMA_LITERT_MAX_NUM_TOKENS \
    GEMMA_LITERT_MAX_OUTPUT_TOKENS \
    GEMMA_LITERT_TEXT_BACKEND \
    GEMMA_LITERT_VISION_BACKEND \
    GEMMA_LITERT_CONSTRAINED_DECODING \
    AILEEN_GEMMA_BRIDGE_DEBUG; do
    if [[ -n "${!forwarded_key:-}" ]]; then
      launch_env+=("SIMCTL_CHILD_${forwarded_key}=${!forwarded_key}")
    fi
  done

  env "${launch_env[@]}" xcrun simctl launch \
    --stdout="$launch_log" \
    --stderr="$launch_log" \
    --terminate-running-process \
    "$device_id" "$BUNDLE_ID" \
    >/dev/null

  local found_results=0
  local expected_scenarios
  expected_scenarios="$(python3 - "$config_path" <<'PY'
import json
import sys
from pathlib import Path

config = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(len(config.get("scenarios", [])))
PY
)"
  local timeout_seconds="${AILEEN_GEMMA_LAB_TIMEOUT_SECONDS:-900}"
  local poll_iterations=$(( (timeout_seconds + 1) / 2 ))
  local _i
  for _i in $(seq 1 "$poll_iterations"); do
    if [[ -f "$result_root/results.json" ]] && python3 - "$result_root/results.json" "$expected_scenarios" <<'PY'
import json
import sys
from pathlib import Path

try:
    results = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
expected = int(sys.argv[2])
finished = len(results.get("scenarios", []))
raise SystemExit(0 if finished >= expected else 1)
PY
    then
      found_results=1
      break
    fi
    sleep 2
  done

  xcrun simctl terminate "$device_id" "$BUNDLE_ID" >/dev/null 2>&1 || true

  if [[ "$found_results" != "1" || ! -f "$result_root/results.json" ]]; then
    echo "Automation run did not produce results.json" >&2
    cat "$launch_log" >&2 || true
    exit 1
  fi

  mkdir -p "$output_root/results"
  cp -R "$result_root/." "$output_root/results/"
  cp "$config_path" "$output_root/config.json"

  local analysis_file="$output_root/ocr-analysis.txt"
  : >"$analysis_file"
  while IFS= read -r rendered_file; do
    "$OVERLAY_LAB_SCRIPT" analyze "$rendered_file" >>"$analysis_file"
  done < <(find "$output_root/results" -type f \( -name '*.jpg' -o -name '*.jpeg' -o -name '*.png' \) | sort)

  printf '%s\n' "$output_root"
}

main "$@"
