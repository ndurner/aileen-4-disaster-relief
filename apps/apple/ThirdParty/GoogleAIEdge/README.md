# Google AI Edge Artifacts

This directory is reserved for Apple-app runtime artifacts derived from
Google-owned upstream projects.

Current intent:

- `LiteRTLM.xcframework`: generated from the official `google-ai-edge/LiteRT-LM`
  repository
- `GemmaModelConstraintProvider.xcframework`: repackaged from official LiteRT-LM
  iOS prebuilts
- `LiteRtMetalAccelerator.xcframework`: repackaged from official `google-ai-edge/LiteRT`
  prebuilts

These files should be treated as generated artifacts, not hand-authored source.
Regenerate them with `apps/apple/scripts/bootstrap_google_ai_edge_artifacts.sh`
before any first commit that keeps them in version control.

Upstream license family: Apache 2.0, as indicated by the bundled public headers
and the upstream Google AI Edge repositories.
