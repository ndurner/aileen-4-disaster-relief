---
title: Aileen Relay Desk
colorFrom: green
colorTo: blue
sdk: gradio
sdk_version: 5.50.0
python_version: 3.12.12
app_file: app.py
models:
  - google/gemma-4-E4B-it
preload_from_hub:
  - google/gemma-4-E4B-it
startup_duration_timeout: 1h
---

# Aileen Relay Desk

Relay Desk is the trusted-recipient browser app for Aileen Desk Mode packages.
It opens the field package, accepts the media that travelled with it, finishes
the same picture and post-text workflow the field app would have run, and
exports the completed package.

It prepares:

- overlaid story visual rendered from the attached photo
- post text
- downloadable ZIP with `aileen-job.yaml` and produced media under `media/`

When the package media provenance rolls up to `synthetic_demo_image`, Relay Desk
stamps the finished story visual with the same small upper-left `AI` disclosure
badge used by the iOS Field Mode renderer.

The browser UI mirrors the iOS app's ocean-light production surface. Static UI
artwork lives under `assets/` and is served with Gradio static paths; it is not
part of the completed field package export.

`PARITY.md` records the iOS/Relay Desk behavior contract. Relay Desk treats a
Desk Mode package as a delayed Field Mode run, not as a separate artifact type.
The exported ZIP writes `execution.mode: field_completed`, preserves
`story.raw`, adds `story.post_body`, and points the single produced still image
at `media/media_001.jpg`.

## ZeroGPU Shape

This app is built for a Hugging Face Gradio Space using ZeroGPU hardware.
Select ZeroGPU in the Space hardware settings.

The app uses:

- `spaces.GPU` on the package-completion function
- `google/gemma-4-E4B-it`
- `AutoProcessor` and `AutoModelForMultimodalLM`
- PyTorch on the ZeroGPU allocation in Space deployment
- Pillow for the local story-image overlay
- Debian font packages from `packages.txt`

It does not call Gemini, does not shell out to a local command, and does not use
Apple frameworks in Space deployment.

ZeroGPU is Gradio-SDK only, so this Space does not use a Dockerfile. System
packages such as fonts belong in `packages.txt`; Hugging Face installs each line
with `apt-get install` during the Space build.

Gemma 4 E4B is preloaded by the Space runtime but lazy-loaded by the Python app.
Importing `app.py` builds the Gradio UI and batchable workflow functions without
constructing the model. The model is loaded on the first generation request. If
the model requires authenticated access in the deployment account, add the
appropriate Hugging Face token as a Space secret.

## Run Locally

Local execution uses the same Python path as the Space and will download the
model weights:

```bash
cd services/relay-desk
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
python app.py
```

On Apple Silicon, local execution selects PyTorch MPS automatically before
falling back to CPU. Override the device when needed:

```bash
AILEEN_RELAY_DEVICE=mps python app.py
```

Valid values are `auto`, `mps`, `cuda`, and `cpu`, subject to local PyTorch
support. The app sets `PYTORCH_ENABLE_MPS_FALLBACK=1` by default so unsupported
MPS operators can fall back instead of aborting the run.

Run the production workflow in batch mode without launching Gradio:

```bash
python relay_batch.py \
  --dataset /tmp/aileen-kaggle-datasets/overlay-placement-benchmark \
  --out /tmp/aileen-relay-batch \
  --limit 2
```

Use `--dry-run` to validate dataset discovery without loading Gemma.
