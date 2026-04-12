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
scripts/shared/inject_models_to_device.sh <device-id> com.ndurner.Aileen4DisasterRelief <model-path> [<model-path> ...]
```

## Notes

- This repository is intentionally structured as a real product workspace, not a
  single sandbox app folder.
- The Apple app and the future datacenter stack are expected to diverge in
  runtime technology even if they share product concepts.
