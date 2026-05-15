# Aileen 4 Disaster Relief Apple App

This app target is the Apple-client side of the product:

- iPhone
- iPad
- Mac via Designed for iPad

Current focus:

- persistent background briefing
- content-production workflow with imported media assets
- Field Mode for creating finished posts locally or in the cloud
- Desk Mode for packaging raw media so a teammate can finish later
- selectable on-device LiteRT-LM or hosted Gemini API processing
- local Gemma 4 LiteRT model download, import, and discovery for on-device runs
- Gemini API key and hosted Gemma 4 model settings for cloud runs
- on-device Apple-native media tool-calling orchestration
- shareable packages containing raw story inputs, media manifests, pre-render
  provenance, GPS metadata, and either generated Field Mode outputs or
  unprocessed Desk Mode media
- a deterministic upper-left `AI` disclosure badge on finished Field Mode media
  when source provenance rolls up to `synthetic_demo_image`

Open the Xcode project:

- `Aileen4DisasterRelief.xcodeproj`

Regenerate it with:

- `apps/apple/scripts/generate_xcodeproj.rb`

Apple-specific support files live alongside the app:

- `apps/apple/ThirdParty/GoogleAIEdge/`: generated LiteRT native artifacts from
  Google-owned upstreams, with provenance notes
- `apps/apple/scripts/shared/inject_models_to_device.sh`: device model injection
- `apps/apple/scripts/bootstrap_google_ai_edge_artifacts.sh`: regenerates the
  Apple binaries from official Google sources instead of relying on opaque local
  copies
- `apps/apple/overlay-lab/`: segregated overlay experiments, local render
  checks, and simulator-driven Gemma overlay runs
- Settings downloads the pinned LiteRT-LM E2B/E4B model files from the
  `litert-community` Hugging Face repositories into the same app-managed model
  folder used by Files imports
- Cloud production calls the Gemini API with field-mode deadlines for unstable
  networks, visible stage labels, explicit timeout errors, and a cancel action
  that unwinds the Production state. Cloud media is uploaded through the Gemini
  Files API, reused across production turns as `fileData`, and deleted after
  the run.

## Collaborator Modes

Field Mode generates here. It runs Gemma 4 on device through LiteRT-LM or in the
cloud through the Gemini API, then exports `aileen-job.yaml` with
`execution.mode: field_completed`, generated `story.post_body`, and finished
media. Image overlay placement uses the shared production correction contract:
after the first render, the model reviews a clean source/grid/outline guide and
must return exact sticker slot coordinates or keep a safe current slot. If the
source media is classified as `synthetic_demo_image`, the app
stamps the finished image or reel with a small upper-left `AI` disclosure badge
after the production overlay is rendered.

Desk Mode generates later. It skips Gemma 4, exports `aileen-job.yaml` with
`execution.mode: remote_generate`, keeps the user prompt in `story.raw`, omits
generated post text, and copies selected media into `media/` unchanged.
The app keeps location, update time, and review notes behind an optional details
section. Time can use image metadata by default, while location defaults to
omitted and can be switched to image-derived or manual when useful. Export
copies the YAML package text to the clipboard and shares media files separately
on iOS, which is intended for messenger handoff workflows.

## Checkout Bootstrap

The Google AI Edge xcframeworks under `apps/apple/ThirdParty/GoogleAIEdge/`
are intentionally not stored in Git history. After a fresh clone, restore them
locally with:

- `apps/apple/scripts/bootstrap_google_ai_edge_artifacts.sh /path/to/google-ai-edge-LiteRT-LM [/path/to/google-ai-edge-LiteRT-prebuilts.zip]`
