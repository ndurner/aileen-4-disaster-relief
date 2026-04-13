# Aileen 4 Disaster Relief

`Aileen 4 Disaster Relief` is a product workspace for disaster-relief media
operations.

The immediate focus is an Apple client that can:

- keep a persistent operational background briefing
- assemble social-media visuals from photos and video
- use Gemma 4 through LiteRT-LM for planning and text generation
- drive a tool-calling media workflow that can eventually render finished
  visuals and reels

A future datacenter-side implementation will live alongside the Apple app in
this same repository, but with a different runtime and deployment model.

## Status

Current repository state:

- Apple app scaffold is in place for iPhone, iPad, and Designed-for-iPad on Mac
- the Apple app uses a LiteRT-LM bridge built around the high-level
  Conversation JSON interface
- model injection is supported for local device testing
- in-app model import from Files is supported
- the content-production workflow is implemented as a first real product shell,
  not another PoC view

Still intentionally incomplete:

- in-app first-party model download
- bundled FFmpeg runtime for iPhone/iPad
- datacenter service implementation
- production hardening and deployment setup

## Repository Layout

```text
.
├── apps/
│   └── apple/                  # Apple client app and Apple-only helpers
├── services/
│   └── datacenter/             # Future server-side product
└── .model-cache-stash/         # Local development-only model cache
```

More specifically:

- `apps/apple/`
  The main Apple app project, including its Xcode project generator, model
  injection helper, and Apple-specific third-party runtime setup.
- `apps/apple/ThirdParty/GoogleAIEdge/`
  Generated LiteRT-related artifacts derived from official Google AI Edge
  upstreams. These are documented as generated artifacts, not hand-authored
  source.
- `services/datacenter/`
  Reserved for the future datacenter-side implementation, which is expected to
  use different serving/runtime choices than the Apple app.
- `.model-cache-stash/`
  Local-only workspace cache for model testing and device injection. This is
  not product source.

## Apple App

The Apple app lives in:

- `apps/apple/Aileen4DisasterRelief.xcodeproj`

Current product areas in the app:

- `Background briefing`
  Persistent large-form operational context entered by the user.
- `Content production`
  Media intake plus Gemma-driven planning for visual output and accompanying
  social text.
- `Settings`
  Model source preference, model import, and runtime-related app settings.

## Model Strategy

The Apple app is currently centered on LiteRT-LM and Gemma 4.

Supported local development routes:

- device injection into the app container
- manual import of `.litertlm` model files through the app

Pinned download URLs:

- E2B: `https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/242c4cb1dc6392c4267c82793ab9a26d92732fbf/gemma-4-E2B-it.litertlm`
- E4B `https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/afca9a55ba2848faee6588e46b47c3164411a903/gemma-4-E4B-it.litertlm`

Reference model pages:

- E2B: `https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm`
- E4B: `https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm`

(see chapter "Development" on how to inject model files into the app container)

The intended direction is to prefer official Google-distributed artifacts and
reproducible generation from official sources over opaque local binaries.

## Third-Party Runtime Policy

This repository tries to keep third-party runtime provenance explicit.

- Apple-side LiteRT artifacts live under `apps/apple/ThirdParty/GoogleAIEdge/`
- each artifact folder carries an origin note
- regeneration is handled by:
  - `apps/apple/scripts/bootstrap_google_ai_edge_artifacts.sh`
- device model injection is handled by:
  - `apps/apple/scripts/shared/inject_models_to_device.sh`

If a first-party prebuilt distribution becomes available for the Apple runtime
surface we need, that should replace local checked-in generated artifacts.

## Development

Regenerate the Apple Xcode project:

```bash
cd apps/apple
ruby scripts/generate_xcodeproj.rb
```

Build quietly for simulator:

```bash
cd apps/apple
scripts/build_apple_quiet.sh simulator
```

Inject models onto a device:

```bash
cd apps/apple
scripts/shared/inject_models_to_device.sh <device-id> <bundle-id> <model-path> [<model-path> ...]
```

Concrete examples:

1. Real iPhone or iPad, starting from a manually downloaded model file:

```bash
mkdir -p .model-cache-stash
curl -L \
  https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/242c4cb1dc6392c4267c82793ab9a26d92732fbf/gemma-4-E2B-it.litertlm \
  -o .model-cache-stash/gemma-4-E2B-it.litertlm

cd apps/apple
xcrun devicectl list devices
scripts/shared/inject_models_to_device.sh \
  6E4F1B88-F27A-5989-888C-F1781C359B9B \
  de.ndurner.Aileen4DisasterRelief \
  ../../.model-cache-stash/gemma-4-E2B-it.litertlm
```

This copies the file inside that app's sandbox on the physical device.

2. Real iPhone or iPad, using the larger Gemma 4 option:

```bash
mkdir -p .model-cache-stash
curl -L \
  https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/afca9a55ba2848faee6588e46b47c3164411a903/gemma-4-E4B-it.litertlm \
  -o .model-cache-stash/gemma-4-E4B-it.litertlm

cd apps/apple
scripts/shared/inject_models_to_device.sh \
  6E4F1B88-F27A-5989-888C-F1781C359B9B \
  de.ndurner.Aileen4DisasterRelief \
  ../../.model-cache-stash/gemma-4-E4B-it.litertlm
```

Re-running the same command is cheap because the script compares a generated
manifest and prints `Reusing injected ...` when nothing changed.

3. Mac app running the Designed-for-iPad target:

Launch the app once from Xcode first, then copy the model into the live app
container.

Do not assume the container path is always:

- `~/Library/Containers/de.ndurner.Aileen4DisasterRelief/Data`

For Xcode-launched Designed-for-iPad builds, the running app may instead use a
UUID-named container under `~/Library/Containers/`. The reliable approach is to
read the active process `HOME` and copy into that sandbox.

```bash
mkdir -p .model-cache-stash
curl -L \
  https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/242c4cb1dc6392c4267c82793ab9a26d92732fbf/gemma-4-E2B-it.litertlm \
  -o .model-cache-stash/gemma-4-E2B-it.litertlm

APP_PID="$(ps aux | awk '/[A]ileen4DisasterRelief.app\/Aileen4DisasterRelief/{print $2; exit}')"
APP_HOME="$(ps eww -p "$APP_PID" | tr ' ' '\n' | sed -n 's/^HOME=//p' | head -n1)"

mkdir -p "$APP_HOME/Library/Application Support/Models"
cp .model-cache-stash/gemma-4-E2B-it.litertlm \
  "$APP_HOME/Library/Application Support/Models/"
```

Restart the app if it was already running so it re-reads the container contents.

## Notes

- This repository is intentionally structured as a real product workspace, not a
  single sandbox app folder.
- The Apple app and the future datacenter stack are expected to diverge in
  runtime technology even if they share product concepts.
