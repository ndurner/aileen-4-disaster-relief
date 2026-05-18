# Aileen 4 Disaster Relief

Aileen 4 is a responder-controlled communications assistant for disaster-relief
teams. It helps a field operator turn a short situational update and selected
media into a reviewed public post when connectivity, battery, and attention are
scarce.

The product is deliberately not an auto-poster. A human writes or approves the
briefing, chooses the media, reviews the output, and decides what gets
published.

## What It Does

- Keeps a persistent background briefing for the organization, audience, tone,
  and safety constraints.
- Imports photos and videos from Camera Roll or Files.
- Produces a social-media visual plus post text from a field update.
- Runs Gemma 4 either on device through LiteRT-LM or in the cloud through the
  Gemini API.
- Packages a Desk Mode handoff when field conditions are too constrained for
  local generation.
- Lets a trusted relay person finish that handoff in a browser with the Gradio
  Relay Desk.
- Preserves source-media provenance, broad location/time context, and review
  notes in a YAML package that can survive messenger and satellite handoffs.

## Product Flow

Field Mode creates the post right on the Apple device. By default, Gemma 4
E2B handles the visual overlay workflow and Gemma 4 E4B handles post text. The
model proposes tool calls; deterministic media code renders the pixels. The results are assembled in a Handoff Package, ready to be sent to the Trusted Relay person.

Desk Mode creates the Handoff Package from raw inputs instead of running inference on-device. The package
contains the raw story, optional field details, review notes, media manifest,
and unprocessed media. A trusted recipient opens it in Relay Desk, attaches the
transferred media, runs Gemma 4 E4B (e.g. on Hugging Face ZeroGPU), reviews the result,
and exports the completed package.

Cloud mode is available from the Apple app when connectivity can support it. It
uses the Gemini API `generateContent` endpoint with hosted Gemma 4 models and
the same tool contract as the on-device path.

## Repository Layout

```text
.
├── apps/apple/              # iPhone, iPad, and Designed-for-iPad-on-Mac app
├── services/relay-desk/     # Gradio app for trusted-recipient completion
└── scratch/                 # Ignored local experiments and validation data
```

The Apple app owns the production client experience. Relay Desk is the
browser-accessible continuation of either Field or Desk mode.

## Quick Start: Apple App
For a clean checkout, use the top-level bootstrap. It prepares the native
LiteRT-LM artifacts from a pinned source checkout, regenerates the Xcode
project, and can run the build:

```bash
scripts/bootstrap_apple.sh \
  --build simulator
```

By default the bootstrap clones `google-ai-edge/LiteRT-LM` under `.build/` and
checks out `v0.10.1`. Version override:
```bash
scripts/bootstrap_apple.sh \
  --litert-ref v0.10.1 \
  --build simulator
```

For local iteration, an existing LiteRT-LM checkout can be reused with
`--litert-src /path/to/google-ai-edge-LiteRT-LM`.

Open the generated Xcode project:

```bash
open apps/apple/Aileen4DisasterRelief.xcodeproj
```

Build quietly from the command line:

```bash
cd apps/apple
scripts/build_apple_quiet.sh simulator
```

Requirements and constraints:

- Xcode with Swift 6 support.
- iOS 17 deployment target.
- Apple Silicon for simulator builds; the generated project excludes x86_64
  simulator builds because the LiteRT artifacts are arm64-only.
- The git-ignored Google AI Edge xcframeworks are prepared by
  `scripts/bootstrap_apple.sh`.

## Apple LiteRT-LM Runtime Artifacts

The app links LiteRT-LM through an Objective-C++ shim in
`apps/apple/Aileen4DisasterRelief/Sources/LiteRTLMBridge/`. The generated Xcode
project expects these local artifacts:

- `apps/apple/ThirdParty/GoogleAIEdge/LiteRTLM.xcframework`
- `apps/apple/ThirdParty/GoogleAIEdge/GemmaModelConstraintProvider.xcframework`

These xcframeworks are intentionally ignored by Git because they are large
generated/native artifacts. The tracked README in that directory records the
expected artifact shape.

The top-level bootstrap calls the lower-level artifact script. If running it
directly, provide the LiteRT-LM source checkout path:

```bash
cd apps/apple
scripts/bootstrap_google_ai_edge_artifacts.sh \
  /path/to/google-ai-edge-LiteRT-LM
```

The first argument must be a LiteRT-LM checkout containing `c/engine.h`. The
script requires `bazel` or `bazelisk` to build `LiteRTLM.xcframework`. If the
first path does not exist, the script clones `google-ai-edge/LiteRT-LM` and
checks out `AILEEN_LITERTLM_REF`.

The runtime currently defaults both LiteRT text and vision backends to CPU for
stability. Debug and experiment overrides are available through environment
variables such as `GEMMA_LITERT_TEXT_BACKEND`,
`GEMMA_LITERT_VISION_BACKEND`, `GEMMA_LITERT_MAX_OUTPUT_TOKENS`, and
`GEMMA_LITERT_MAX_NUM_TOKENS`.

## On-Device Model Files

Large `.litertlm` model files are not stored in this repository. The Apple app
can get them in three ways:

- Download pinned Gemma 4 E2B/E4B LiteRT-LM files from Settings.
- Import a matching `.litertlm` file from Files.
- Inject files into the app sandbox for development or preloaded devices.

Device injection:

```bash
cd apps/apple
xcrun devicectl list devices
scripts/shared/inject_models_to_device.sh \
  <device-id> \
  de.ndurner.Aileen4DisasterRelief \
  /path/to/gemma-4-E2B-it.litertlm \
  /path/to/gemma-4-E4B-it.litertlm
```

The script copies models into `Library/Application Support/Models` inside the
app container and reuses existing files when its generated manifest matches.

## Cloud Gemma

The Apple app's cloud path uses Gemini API keys and hosted Gemma 4 model IDs:

- `gemma-4-26b-a4b-it`
- `gemma-4-31b-it`

Images are uploaded through the Gemini Files API and referenced from
`generateContent` as `fileData`. The app deletes uploaded files after each
production run and treats Gemini's temporary retention as a fallback.

## Quick Start: Relay Desk

Relay Desk lives in `services/relay-desk/` and is designed to be pushed to a
Hugging Face Gradio Space using ZeroGPU hardware. A live demo currently [runs here](https://huggingface.co/spaces/ndurner/aileen-relay-desk).

Run locally:

```bash
cd services/relay-desk
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
python app.py
```

Local execution uses the same Python code path as the Space and downloads the
selected model on first generation. On Apple Silicon, it selects MPS
automatically when available and uses `google/gemma-4-E2B-it`; CUDA, ZeroGPU,
and CPU use `google/gemma-4-E4B-it`. Override the device with:

```bash
AILEEN_RELAY_DEVICE=cpu python app.py
```

Valid `AILEEN_RELAY_DEVICE` values are `auto`, `mps`, `cuda`, and `cpu`.

Run the batch harness without launching Gradio:

```bash
cd services/relay-desk
python relay_batch.py \
  --dataset /tmp/aileen-kaggle-datasets/overlay-placement-benchmark \
  --out /tmp/aileen-relay-batch \
  --limit 2
```

Use `--dry-run` to validate dataset discovery without loading Gemma.

## Handoff Package

Aileen packages are plain YAML so the operational context can travel separately
from fragile image metadata:

```yaml
aileen_job_version: 1
execution:
  mode: remote_generate # or field_completed after generation
story:
  raw: |-
    Field update written by the responder.
field_update:
  location_label: "Ningaloo coast"
  update_time_local: "Apr 4, 2026 afternoon"
  review_notes: |-
    Keep public location broad; avoid exact rescue or staging locations.
media:
  - id: media_001
    filename: "media/photo_001.jpg"
    type: photo
    source_type: field_photo # field_photo, synthetic_demo_image, or unknown
```

Finished Field Mode and Relay Desk outputs write `execution.mode:
field_completed`, add generated `story.post_body`, and point media entries at
produced files under `media/`.

If media provenance rolls up to `synthetic_demo_image`, the renderer adds a
small visible `AI` badge in the upper-left corner after the model-produced
overlay is rendered.

## Overlay Tool Contract

Gemma sees a small media-tool interface:

- `compose_visuals`
- `add_text_overlay`
- `move_text_overlay`
- `accept_overlay_layout`

The model returns intent. The app or Relay Desk validates arguments, measures
text, renders overlays, and feeds tool results back to the model. A correction
turn reviews a clean source frame with grid and outline guides so the model can
move an overlay away from people, animals, hands, equipment, and other
story-critical content without editing source pixels directly.

This contract is intentionally kept in parity across:

- iOS on-device LiteRT-LM processing
- iOS cloud Gemini API processing
- Relay Desk Transformers processing

Relay Desk parity notes live in `services/relay-desk/PARITY.md`.

## Current Status

Implemented:

- Apple client for Field Mode and Desk Mode.
- On-device Gemma 4 through LiteRT-LM.
- Hosted Gemma 4 through the Gemini API.
- Apple-native image and reel rendering with AVFoundation, CoreImage,
  CoreGraphics, ImageIO, and UIKit.
- Relay Desk Gradio app for still-image Desk Mode completion.
- YAML package export/import for field handoffs.
- Overlay lab and batch harnesses for placement-regression work.

## Related Docs

- `apps/apple/README.md`: Apple app setup and runtime notes.
- `apps/apple/ThirdParty/GoogleAIEdge/README.md`: LiteRT-LM artifact
  provenance and restore expectations.
- `apps/apple/overlay-lab/README.md`: overlay experimentation workflow.
- `services/relay-desk/README.md`: Hugging Face Space and local Relay Desk
  setup.
- `services/relay-desk/PARITY.md`: iOS/Relay Desk behavior contract.
