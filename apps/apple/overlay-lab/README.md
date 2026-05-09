# Overlay Lab

This folder contains the overlay experimentation harness for the Apple app. It is intentionally segregated from the main app README and from production app code so prompt/interface experiments stay auditable.

## Layout

- `scripts/overlay_lab.sh`: fast local renderer/OCR harness built around the shared `OverlayCore.swift`.
- `scripts/overlay_quality_harness.py`: batch harness for comparing the Swift renderer, the Relay Desk Pillow renderer, optional LiteRT simulator runs, and optional Codex VLM grading.
- `scripts/build_kaggle_overlay_dataset.py`: assembles a Kaggle-ready overlay-placement benchmark from the active synthetic test set.
- `scripts/run_gemma_overlay_lab.sh`: simulator-driven Gemma 4 E2B benchmark runner.
- `scripts/remove_overlay_text_from_samples.py`: helper for generating rough overlay-free variants from reference screenshots.
- `schemas/codex_overlay_grade.schema.json`: structured response schema for non-interactive Codex overlay grading.
- `../Aileen4DisasterRelief/Sources/OverlayLab/AutomationLab.swift`: app-side automation entrypoint used by the simulator runs.
- `../../../services/relay-desk/relay_batch.py`: batch entrypoint for the Relay Desk production workflow without launching Gradio.

## Typical Usage

Render variants quickly without launching the app:

```bash
apps/apple/overlay-lab/scripts/overlay_lab.sh analyze /tmp/insta-samples/*
apps/apple/overlay-lab/scripts/overlay_lab.sh render --text "Urban moments" --style sticker /tmp/test-imgs/*
```

Run a quick cross-renderer placement suite over the synthetic test set:

```bash
services/relay-desk/.venv/bin/python \
  apps/apple/overlay-lab/scripts/overlay_quality_harness.py \
  --dataset scratch/synthetic_testset \
  --limit 2 \
  --grade none
```

The default harness run renders `worst-top` and `lower-sticker` placements with:

- `swift-fixture`: uses `overlay_lab.sh render`, and therefore the shared Swift `OverlayCore`.
- `relay-fixture`: uses a small Pillow fixture that mirrors the Relay Desk renderer geometry closely enough for fast local parity checks.

Outputs are written under `/tmp/aileen-overlay-quality/run-NNNN/` with `manifest.json`, `results.json`, `results.csv`, and rendered image artifacts.

Assemble a Kaggle-ready dataset package from the synthetic fixtures:

```bash
services/relay-desk/.venv/bin/python \
  apps/apple/overlay-lab/scripts/build_kaggle_overlay_dataset.py \
  --clean \
  --dataset-id YOUR_KAGGLE_USERNAME/aileen-overlay-placement-benchmark
```

The packager writes a publishable folder under `/tmp/aileen-kaggle-datasets/overlay-placement-benchmark/` with `dataset-metadata.json`, `README.md`, `cases.csv`, `cases.jsonl`, `control_placements.csv`, `benchmark_config.json`, copied images/stories, and the Codex grading schema. The copied PNGs under `images/` are dataset payload files. They are not Kaggle cover-image metadata; Kaggle uses the separate `dataset-cover-image.*` filename convention for that. The package intentionally excludes local private validation photos and Gemma/LiteRT model files. The generated folder also contains `publish_to_kaggle.sh`, which runs `kaggle datasets create -p . --dir-mode zip` after the Kaggle CLI is installed and authenticated.

The quality harness can consume that packaged folder directly:

```bash
services/relay-desk/.venv/bin/python \
  apps/apple/overlay-lab/scripts/overlay_quality_harness.py \
  --dataset /tmp/aileen-kaggle-datasets/overlay-placement-benchmark \
  --grade none
```

To use Codex as the visual grader, run:

```bash
services/relay-desk/.venv/bin/python \
  apps/apple/overlay-lab/scripts/overlay_quality_harness.py \
  --dataset scratch/synthetic_testset \
  --limit 2 \
  --grade codex
```

This shells out to `codex exec` with each rendered image attached and requires a local Codex CLI login. It is useful during a Codex Desktop iteration session, but should be treated as an interactive lab grader rather than a stable CI dependency.

Run the Gemma 4 E2B lab on saved inputs:

```bash
apps/apple/overlay-lab/scripts/run_gemma_overlay_lab.sh /tmp/test-imgs/*
```

Outputs are written to `/tmp/aileen-overlay-lab` or `/tmp/aileen-gemma-overlay-runs` unless overridden by environment variables in the scripts.
For production-parity prompts, place a same-stem `.txt` file next to each
image; the simulator lab stages it as the UI "Story prompt" field. A same-stem
`.briefing.txt`, directory-level `background_briefing.txt`, directory-level
`briefing.txt`, or `AILEEN_GEMMA_BACKGROUND` supplies the UI background
briefing. If no briefing is provided, the field is intentionally blank.
The simulator lab forwards LiteRT bridge overrides such as
`GEMMA_LITERT_MAX_NUM_TOKENS`, `GEMMA_LITERT_MAX_OUTPUT_TOKENS`, backend
selection, constrained decoding, and bridge debug logging into the launched app
process. The app defaults to an 8192-token LiteRT engine budget and a
1200-token output cap so thinking-mode generations have enough room to reach
tool calls without sprawling indefinitely.

The quality harness can also delegate to this simulator path:

```bash
services/relay-desk/.venv/bin/python \
  apps/apple/overlay-lab/scripts/overlay_quality_harness.py \
  --backend litert-ios \
  --dataset scratch/synthetic_testset \
  --limit 2
```

Run the Relay Desk Transformers production path in batch mode:

```bash
services/relay-desk/.venv/bin/python \
  apps/apple/overlay-lab/scripts/overlay_quality_harness.py \
  --backend transformers-relay \
  --dataset /tmp/aileen-kaggle-datasets/overlay-placement-benchmark \
  --limit 2
```

This uses `services/relay-desk/relay_batch.py`, which imports the same Relay Desk production workflow used by Gradio. The Hugging Face model is lazy-loaded only when generation starts, so the batch runner can be imported and dry-run without paying model startup cost.
Relay batch runs enable Gemma thinking by default and write `raw_responses`,
`thought_traces`, and `thinking_enabled` into `results.jsonl` for correction
stage debugging. Set `AILEEN_RELAY_ENABLE_THINKING=0` only when comparing
against the no-thinking behavior. Thinking runs default to
`AILEEN_RELAY_MAX_NEW_TOKENS=1200` to reduce local MPS memory pressure; override
that only when diagnosing truncated thoughts or tool calls.

For wiring checks that should not load Gemma, add `--relay-dry-run`.
