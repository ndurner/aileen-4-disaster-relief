# Aileen 4 Disaster Relief Apple App

This app target is the Apple-client side of the product:

- iPhone
- iPad
- Mac via Designed for iPad

Current focus:

- persistent background briefing
- content-production workflow with imported media assets
- local Gemma 4 LiteRT model management
- on-device Apple-native media tool-calling orchestration
- shareable visual and text outputs

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

## Checkout Bootstrap

The Google AI Edge xcframeworks under `apps/apple/ThirdParty/GoogleAIEdge/`
are intentionally not stored in Git history. After a fresh clone, restore them
locally with:

- `apps/apple/scripts/bootstrap_google_ai_edge_artifacts.sh /path/to/google-ai-edge-LiteRT-LM [/path/to/google-ai-edge-LiteRT-prebuilts.zip]`
