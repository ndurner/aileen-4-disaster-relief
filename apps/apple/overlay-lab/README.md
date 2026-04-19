# Overlay Lab

This folder contains the overlay experimentation harness for the Apple app. It is intentionally segregated from the main app README and from production app code so prompt/interface experiments stay auditable.

## Layout

- `scripts/overlay_lab.sh`: fast local renderer/OCR harness built around the shared `OverlayCore.swift`.
- `scripts/run_gemma_overlay_lab.sh`: simulator-driven Gemma 4 E2B benchmark runner.
- `scripts/remove_overlay_text_from_samples.py`: helper for generating rough overlay-free variants from reference screenshots.
- `../Aileen4DisasterRelief/Sources/OverlayLab/AutomationLab.swift`: app-side automation entrypoint used by the simulator runs.

## Typical Usage

Render variants quickly without launching the app:

```bash
apps/apple/overlay-lab/scripts/overlay_lab.sh analyze /tmp/insta-samples/*
apps/apple/overlay-lab/scripts/overlay_lab.sh render --text "Urban moments" --style sticker /tmp/test-imgs/*
```

Run the Gemma 4 E2B lab on saved inputs:

```bash
apps/apple/overlay-lab/scripts/run_gemma_overlay_lab.sh /tmp/test-imgs/*
```

Outputs are written to `/tmp/aileen-overlay-lab` or `/tmp/aileen-gemma-overlay-runs` unless overridden by environment variables in the scripts.
