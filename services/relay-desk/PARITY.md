# Relay Desk / iOS Parity Contract

Relay Desk is the receiving-side continuation of iOS Desk Mode. It should not be
a separate content generator with separate artifacts. A Desk Mode package is a
delayed Field Mode run: the field app sends raw inputs, and Relay Desk completes
the same production workflow later.

## Product Contract

| Concern | iOS Field Mode | iOS Desk Mode package | Relay Desk target |
| --- | --- | --- | --- |
| Input story | App state story prompt | `story.raw` | Read `story.raw` |
| Background briefing | App state, not YAML | Copied separately if needed | Separate optional input |
| Media | selected app assets | unprocessed files under `media/` | uploaded transferred media |
| Execution mode | `field_completed` after production | `remote_generate` | export completed package as `field_completed` |
| Visual generation | model calls media tools | omitted | same media-tool loop |
| Main visual output | rendered image/reel with overlay | raw media only | rendered image with overlay |
| Post body | second plain-text model pass | omitted | same second plain-text model pass |
| Export media | produced media in `media/` | raw media in `media/` | produced media in `media/` |

Relay Desk must preserve the current Hugging Face / ZeroGPU / MPS runtime path,
but the product behavior should mirror the iOS workflow.

## Staged Workflow

1. Parse `aileen-job.yaml`.
2. Build production assets named `asset_1`, `asset_2`, ... from uploaded media.
3. Build the visual prompt equivalent to `ProductionPrompts.productionPrompt`.
4. Give the model the same visual tools:
   - `compose_visuals`
   - `add_text_overlay`
   - `move_text_overlay`
   - `accept_overlay_layout`
5. Execute tool calls locally and return media-tool payloads to the model.
6. Require at least one rendered visual produced by `add_text_overlay` or
   `move_text_overlay`.
7. Build the post-body prompt equivalent to `ProductionPrompts.postBodyPrompt`.
8. Generate the post body as plain text, not as a tool call. The post body is
   the creative artifact, so the tool-call container should not constrain it or
   introduce avoidable wire-format failures.
9. Export a completed package:
   - `aileen-job.yaml`
   - `media/media_001.jpg`

## Current Scope

This Relay Desk implementation targets still-image Desk Mode packages. The iOS
app also supports reel generation, but the current satellite handoff guidance
already steers users toward still photos. Reels should be added only when the
job card carries an explicit output kind and the receiving environment has
matching video rendering support.

## Non-Parity Artifacts

Do not add Relay Desk-only public outputs such as `alt_text`, `relay_note`, or
`recipient_checklist` unless the same outputs are added to the iOS app and YAML
schema. They are useful future artifacts, but they are not part of current iOS
Field Mode parity.

## Known Gaps To Track

- The current YAML does not carry `output_kind`, so Relay Desk defaults to the
  iOS image canvas (`1080 x 1350`).
- The Python overlay renderer should stay aligned with `OverlayCore.swift`; it
  is acceptable as a local mirror only if it accepts the same tool arguments and
  returns the same payload shape.
- Relay Desk must aspect-fill source still images into the `1080 x 1350`
  canvas before drawing overlays. Directly resizing source photos to the canvas
  shape is a bug because it distorts subjects and invalidates placement tests.
- Full Gemma overlay pre-analysis can be added later by porting
  `submit_overlay_layout_guide` and the `OverlayLayoutGuidance` addendum.
