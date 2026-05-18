---
title: Aileen Relay Desk
colorFrom: green
colorTo: blue
sdk: gradio
sdk_version: 6.14.0
python_version: 3.12.12
app_file: app.py
models:
  - google/gemma-4-E2B-it
  - google/gemma-4-E4B-it
preload_from_hub:
  - google/gemma-4-E4B-it
startup_duration_timeout: 1h
---

# Aileen Relay Desk

Relay Desk is the trusted-recipient browser app for Aileen Desk Mode packages.
It lets someone with better connectivity and more time finish the same workflow
the field app would have run locally.

The operator loads `aileen-job.yaml`, attaches the media that travelled with the
handoff, optionally adds the background briefing, reviews the generated result,
and downloads a completed package for posting on social media. Use **Load
sample** to populate both the demo package and included sample synthetic photo
for a no-extra-material trial run.

Relay Desk produces:

- an overlaid story image
- post text
- a ZIP containing `aileen-job.yaml` and produced media under `media/`

In Space deployment it runs Gemma 4 E4B through Transformers on Hugging Face
ZeroGPU, then renders the final still image with Pillow.

## Package Contract

Relay Desk treats Desk Mode as a delayed Field Mode run:

- Input package: `execution.mode: remote_generate`
- Output package: `execution.mode: field_completed`
- Preserved field story: `story.raw`
- Added generated caption: `story.post_body`
- Top-level caption text file: `finished-post.txt`
- Produced media paths under `media/`

When an uploaded or pasted package is already
`execution.mode: field_completed`, Relay Desk skips Gemma inference on
**Finish package**. It uses `story.post_body` from the package and copies every
attached image into the finished post output.

If package provenance rolls up to `synthetic_demo_image`, the produced image is
stamped with the same small upper-left `AI` disclosure badge used by the iOS
renderer.

## Runtime Shape

This Space is configured for the Gradio 6 SDK with ZeroGPU hardware. Use the
Space hardware settings to select ZeroGPU; do not convert this app to a
Dockerfile Space for the current deployment path.

Main runtime pieces:

- `spaces.GPU` wraps the package-completion function.
- `google/gemma-4-E4B-it` is the default model for CUDA and CPU.
- `google/gemma-4-E2B-it` is the default model for local MPS.
- `AutoProcessor` and `AutoModelForMultimodalLM` provide the Transformers path.
- PyTorch runs on the ZeroGPU allocation in Space deployment.
- Pillow renders the overlay image.
- `packages.txt` installs Debian font packages during the Space build.

The model is lazy-loaded on the first generation request. Importing `app.py`
builds the Gradio UI and workflow functions without constructing Gemma. If the
deployment account needs authenticated access to the model, add the required
Hugging Face token as a Space secret.

## Run Locally

Local execution uses the same Python path as the Space and downloads the selected
model weights on first generation:

```bash
cd services/relay-desk
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
python app.py
```

On Apple Silicon, local execution selects PyTorch MPS automatically before
falling back to CPU. The default model follows the active device: MPS uses
`google/gemma-4-E2B-it`; CUDA, ZeroGPU, and CPU use `google/gemma-4-E4B-it`.
Override the device when needed:

```bash
AILEEN_RELAY_DEVICE=mps python app.py
```

Valid values are `auto`, `mps`, `cuda`, and `cpu`, subject to local PyTorch
support. The app sets `PYTORCH_ENABLE_MPS_FALLBACK=1` by default so unsupported
MPS operators can fall back instead of aborting the run.

Useful environment variables:

```bash
AILEEN_RELAY_MODEL_ID=google/gemma-4-E4B-it  # explicit override
AILEEN_RELAY_ENABLE_THINKING=1
AILEEN_RELAY_MAX_NEW_TOKENS=1200
AILEEN_RELAY_GPU_SECONDS=180
AILEEN_RELAY_DEVICE=auto
```

Disable thinking only for explicit comparisons:

```bash
AILEEN_RELAY_ENABLE_THINKING=0 python app.py
```

## Batch Harness

Run the production workflow without launching Gradio:

```bash
python relay_batch.py \
  --dataset /tmp/aileen-kaggle-datasets/overlay-placement-benchmark \
  --out /tmp/aileen-relay-batch \
  --limit 2
```

Use `--dry-run` to validate dataset discovery without loading Gemma.

Batch runs capture raw model responses and extracted thinking traces so prompt,
tool-call, and placement failures can be compared against iOS and simulator
artifacts.
