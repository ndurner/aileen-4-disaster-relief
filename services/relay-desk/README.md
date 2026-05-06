---
title: Aileen Relay Desk
colorFrom: teal
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
the public update in the Space, and exports the final recipient package.

It prepares:

- labeled story visual rendered from the attached photo
- social caption
- alt text
- compact relay note
- recipient review checklist
- downloadable ZIP with the original package, original media, text artifacts,
  and `outputs/story-visual.jpg`

## ZeroGPU Shape

This app is built for a Hugging Face Gradio Space using ZeroGPU hardware.
Select ZeroGPU in the Space hardware settings.

The app uses:

- `spaces.GPU` on the package-completion function
- `google/gemma-4-E4B-it`
- `AutoProcessor` and `AutoModelForMultimodalLM`
- PyTorch on the ZeroGPU allocation
- Pillow for the final story-image overlay
- Debian font packages from `packages.txt`

It does not call Gemini, does not shell out to a local command, and does not use
Apple frameworks.

ZeroGPU is Gradio-SDK only, so this Space does not use a Dockerfile. System
packages such as fonts belong in `packages.txt`; Hugging Face installs each line
with `apt-get install` during the Space build.

Gemma 4 E4B is loaded when the Space starts. The Space README preloads the model
from the Hub to reduce startup friction. If the model requires authenticated
access in the deployment account, add the appropriate Hugging Face token as a
Space secret.

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
