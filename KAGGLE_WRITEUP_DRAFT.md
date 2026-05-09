# Aileen: On-Device Social Visual Composition With Gemma 4

## Gemma 4 for Native Mobile Creative Tool-Calling

### Track

Gemma 4 Native / On-Device Applications

### Subtitle

An iPhone-first content production workflow that uses Gemma 4 E2B to compose visuals, choose overlay copy, and guide overlay placement from rendered frames instead of brittle fixed templates.

## Abstract

This project explores a practical mobile AI problem: creating Instagram-style image and reel overlays that feel current, not templated, while still running on-device on constrained Apple hardware. The app uses Gemma 4 E2B through a native LiteRT tool-calling pipeline to compose media, choose overlay wording, and guide where overlays should land. The core challenge was not generating text. It was getting a small on-device multimodal model to place overlays in aesthetically plausible regions without covering the subject.

The final direction is a hybrid one. Gemma 4 is used for semantic and visual understanding, while deterministic Swift code owns rendering, measured layout, duplicate suppression, and the final placement search inside model-guided safe regions. This was the right tradeoff for iPhone-class hardware: it reduced RAM pressure, avoided overfitting to exact pixel coordinates, and produced a system that can be iterated and benchmarked quickly. A second engineering challenge turned out to be runtime stability: long multimodal tool loops on LiteRT-LM could fail mid-run, so part of the work became making the on-device Gemma loop reliable enough for a real app.

## Problem

The initial codebase always produced overlays near the very top of the frame. That made outputs look like old banners rather than current Instagram story or reel graphics. It also made placement fragile: once the overlay style changed or the subject was large, the text often sat directly on the subject.

The problem split into four subproblems:

1. Make overlay rendering flexible enough to support modern visual treatments.
2. Give Gemma 4 a tool interface that is realistic for its visual precision budget.
3. Evaluate results with actual rendered images rather than trusting prompts or tool arguments.
4. Find a recipe that works on subject-heavy images and open scenic images without requiring a large second model or cloud inference.

## Architecture

The repository currently contains:

- `apps/apple`: the iOS / iPadOS / Designed-for-iPad Mac app
- `services/datacenter`: reserved for future backend work, not implemented

The relevant app architecture is:

1. Gemma 4 E2B runs on-device through LiteRT.
2. A Swift tool-calling engine gives Gemma a small set of media tools.
3. Native Apple rendering code performs visual composition and text overlay rendering.
4. The export path writes an Aileen YAML package containing the rendered output,
   generated post text, and pre-render media provenance.
5. An automation lab runs prompt and interface experiments over saved images and writes comparable artifacts and scores.

The key files are:

- `apps/apple/Aileen4DisasterRelief/Sources/AppModule/GemmaToolCallingEngine.swift`
- `apps/apple/Aileen4DisasterRelief/Sources/AppModule/MediaTooling.swift`
- `apps/apple/Aileen4DisasterRelief/Sources/AppModule/OverlayCore.swift`
- `apps/apple/Aileen4DisasterRelief/Sources/AppModule/OverlayVisionGuidance.swift`
- `apps/apple/Aileen4DisasterRelief/Sources/OverlayLab/AutomationLab.swift`
- `apps/apple/overlay-lab/scripts/run_gemma_overlay_lab.sh`

The YAML package is deliberately not just a convenience wrapper around files.
Overlay rendering can invalidate embedded C2PA manifests, and the messaging app
used to send the result may strip whatever metadata survives rendering. The
package therefore carries the best provenance signal observed before rendering
alongside the produced image or reel. A generated-source C2PA/IPTC digital source
type is preserved as `synthetic_demo_image`; ordinary camera-roll images with
camera metadata are preserved as `field_photo`; ambiguous imports remain
`unknown`. If the selected source media has one unambiguous GPS coordinate, that
coordinate is carried into the YAML media entry as well.

## How Gemma 4 Is Used

Gemma 4 is not used as a generic chatbot wrapper. It is used in three distinct roles:

### 1. Production tool-calling model

Gemma receives:

- the user briefing and story text
- source media assets
- the rendered output canvas dimensions
- optional visual guidance about subject keep-clear regions and free-space patches

It can call two core tools:

- `compose_visuals`
- `add_text_overlay`

This keeps the action space small and makes model behavior auditable. In the current app path, Gemma runs with thinking mode enabled, but the conversation is reset around each newly rendered frame instead of carrying an ever-growing multimodal history.

### 2. Visual guidance model

Gemma is asked to inspect a rendered frame and return:

- a subject keep-clear box
- a free-space patch
- style hints
- suggested anchors and width limits

This is implemented in `apps/apple/Aileen4DisasterRelief/Sources/AppModule/OverlayVisionGuidance.swift`.

### 3. Evaluation model

Freeform aesthetic review by Gemma turned out to be too permissive and too unstable. The better use of Gemma for evaluation was bbox-style analysis of the final rendered output. The current lab uses Gemma visual analysis on the rendered result itself to estimate whether the overlay intrudes into the subject or its safety margin.

## Why E2B

The app is built around the Gemma 4 E2B variant because the target hardware includes iPhone 14 Pro class devices. E2B is the realistic deployment option for this hackathon constraint. The work therefore focused on interfaces and renderer logic that cooperate with a smaller on-device multimodal model instead of assuming cloud-scale spatial precision.

## Core Technical Decisions

### Decision 1: Move from exact coordinates to measured layout

At first, the model was effectively guessing final pixel boxes. That overfit quickly and failed once text length or frame composition changed.

The interface was changed so Gemma can provide:

- `top_fraction`
- `max_width_fraction`
- `target_line_count`
- anchors
- optionally a slot rectangle

The renderer then measures the text and chooses the final box size. This produced less uniform overlays and made the results look closer to the Instagram references.

### Decision 2: Use rendered-frame guidance, not raw source-image reasoning

The app composes the source assets first and then asks Gemma to reason over the rendered frame. This matters because crop and aspect-fill decisions can move the visible subject relative to the original source.

### Decision 3: Separate semantics from rendering

Gemma is good enough to suggest what is in the frame and where space may exist. It is not consistently reliable enough on E2B to own the exact final overlay geometry. Swift rendering code handles:

- measured text layout
- deduplication of repeated overlays
- style application
- placement search against protected regions

This hybrid design was the most robust result of the session.

### Decision 4: Benchmark against real rendered artifacts

Earlier heuristic scores were too optimistic. We corrected this by:

- inspecting actual rendered files
- adding checkpointed lab runs
- scoring the rendered output itself
- using Gemma bbox-style evaluation on the final image

This made it much harder for a visually bad result to hide behind a clean-looking tool call.

## Major Challenges

### Challenge 1: Top-banner bias

The initial system consistently produced overlays too high in the frame. Prompt changes alone improved this only slightly.

### Challenge 2: Subject overlap

Many outputs looked plausible until inspected visually, then failed because the label sat on the animal or person. This was especially hard on centered-subject images.

### Challenge 3: Gemma thinking mode tradeoff

Gemma `enable_thinking=true` improved wording, but in the early monolithic tool loop it often hurt geometry-sensitive placement and made the model rationalize weak choices. The useful lesson was not “thinking is bad.” It was that thinking mode needed a better conversation boundary.

After checking the official Gemma 4 guidance, we also changed how thinking traces were handled. In multi-turn use, prior model history should contain only the model's final response, not its thought content. We therefore stopped surfacing thought-channel text in user-visible summaries and stripped thought-channel payloads from any assistant history that might be replayed for recovery. Thought traces remain a lab-only diagnostic artifact, not production conversation state.

An additional, less obvious lesson came from running the same faithful prompt on a real iPad with different output-token budgets while keeping thinking enabled. We originally treated thinking as an on/off toggle. In practice, the *budget* available to thinking mode materially changed both quality and runtime behavior.

On the iPad, the `IMG_0289` faithful case completed at `1024`, `4000`, and `8000` output-token caps. The `4000` run produced the best story-grounded copy (`#BinLife` survived into the final overlay), completed in fewer turns, and showed a lower peak resident-memory trace in our bridge logs than the `1024` run. Increasing the cap again to `8000` remained stable on-device, but quality regressed toward a more generic rewrite and memory climbed again. In other words, the effect was real, but not monotonic.

However, broader testing showed that `4000` is not a universal optimum. On the grocery-delivery image (`IMG_0533`), `1024` and `8000` both stayed closer to the user story than `4000`, while `4000` became slower, more editorialized, and more memory-hungry. On the harder close-up wildlife image (`IMG_7613`), the device run at `1024` completed, but the higher-budget sweep became materially less reliable and exposed a practical stability cost on harder multimodal cases.

Repeating the experiment on the simulator showed the same broad pattern on `IMG_0289`: `1024` flattened the story into a generic “peace amidst the cleanup” line, `4000` preserved the user-specific `#BinLife` angle best, and `8000` drifted back toward a more editorial rewrite. The grocery image also reproduced the non-monotonic behavior on the simulator: `4000` was worse than both `1024` and `8000` in wording quality. This does **not** prove anything deep about Gemma’s internal architecture, but it does show that thinking-mode behavior is budget-sensitive in a way that materially affects both quality and runtime across both device and simulator.

### Challenge 4: Evaluation drift

Gemma freeform review sometimes approved visibly bad placements. Bbox-style post-analysis was more useful than subjective review for catching overlap.

### Challenge 5: Long-running experiment reliability

The automation lab initially lost results when a run timed out. We fixed this by checkpointing after each scenario and by adding a non-progressing tool-call cutoff so repeated duplicate overlays cannot hang the run indefinitely.

### Challenge 6: LiteRT-LM send instability

The most serious engineering obstacle was runtime instability in longer guided runs. The two-phase Gemma path could fail with `LiteRT-LM failed to send message` after several multimodal turns, especially when large rendered-frame images were kept in the same conversation history.

The fix was not to abandon the guided path. The fix was to change conversation lifecycle:

- keep the E2B engine loaded
- do Gemma pre-analysis on a base render
- when a new rendered frame is produced, restart the conversation around that latest frame plus a compact task/tool recap
- keep a full session rebuild retry as a safety fallback

This turned the previously flaky guided path into a stable one on the benchmark images.

### Challenge 7: Gemma 4 tool-call wire-format edge cases

The Relay Desk prototype also exposed a parser interoperability issue that is separate from the iOS LiteRT path. When running `google/gemma-4-E4B-it` through Hugging Face Transformers for the desk-side Gradio app, the model produced a malformed native Gemma 4 tool call in a deterministic post-body test:

```text
<|tool_call>call:submit_post_body{post_body_text:"Checking in on the sheltered recovery area this afternoon. Several animals are stable after overnight care. Remember to call a trained carer before approaching injured wildlife."<|"|>}<turn|>
```

That output combines two problems:

- the tool call starts with `<|tool_call>` but is not closed with `<tool_call|>` before `<turn|>`
- the string argument opens with a normal JSON quote but closes with Gemma's `<|"|>` string delimiter

The canonical Gemma 4 form should look more like:

```text
<|tool_call>call:submit_post_body{post_body_text:<|"|>...<|"|>}<tool_call|><turn|>
```

This was reproduced cleanly with a deterministic decoding probe (`do_sample=False`), the sample Desk package, the bundled production-scene image, and the post-body tool schema. That probe was used only to make the bug easy to reproduce; it is not the production generation setting for Gemma 4 E4B, whose model-card defaults use `do_sample=True`, `temperature=1.0`, `top_p=0.95`, and `top_k=64`. A repeat run reproduced the same deterministic malformed string.

A more realistic 12-run probe with the model-card sampling settings showed that the exact deterministic malformed string is not the main production concern. Instead, required tool calling was unstable across several adjacent failure modes: 6 of 12 generations became parseable after normalization, 3 produced plain text or thought traces instead of a tool call, 3 used the hybrid quote delimiter pattern, 7 started a tool call without a proper `<tool_call|>` terminator, 4 ended at `<eos>` before a normal turn boundary, and 2 remained unparseable even after the current normalizer. The raw decoded deterministic response contained the malformed form; a small normalizer repaired the terminator and quote delimiters, after which Hugging Face's own `processor.parse_response()` parsed the tool call correctly. The lesson is that the app should use the model/runtime's native response parser as the authority, but keep test coverage around exact decoded wire strings because newly released tool-call formats can fail at the boundary between model output, chat template, tokenizer schema, and application code.

## Experimental Progress

The project moved through several interface generations:

### Phase 1: Direct overlay placement

Gemma called `add_text_overlay` with raw coordinates and produced many top-heavy, uniform results.

### Phase 2: Normalized hints

We introduced:

- `top_fraction`
- `max_width_fraction`
- `target_line_count`
- anchors

This improved renderer flexibility but did not solve subject overlap by itself.

### Phase 3: Gemma visual guidance

Gemma was asked for:

- a keep-clear subject box
- a recommended free-space patch

This improved some cases substantially, especially the ibis image, but remained brittle on central subjects.

### Phase 4: Guarded hybrid placement

The renderer began using protected regions derived from Gemma guidance, not just relying on prompt obedience. This improved failure containment and made the placement system more deterministic.

### Phase 5: Code-owned slot placement

The current direction is to use Gemma mostly for subject understanding while code derives the final candidate patch or slot. This is the most promising route so far.

### Phase 6: Fresh-frame conversation resets

The final runtime architecture stopped treating the overlay workflow as one giant multimodal conversation. Instead, each newly rendered frame becomes the anchor for a fresh Gemma turn. This preserved the benefits of thinking mode and rendered-frame reasoning while removing the send failures that were blocking reliable app integration.

An equally important part of this phase was stopping the system from dragging full multimodal history forward. That reduced LiteRT memory pressure and aligned the runtime with Gemma 4's guidance for thought-enabled multi-turn conversations.

### Phase 7: Coordinate scaffolds and clean-frame correction

Two late changes produced an outsized improvement in manual testing.

The first was adding an explicit coordinate scaffold for correction-stage
reasoning. Inspired by grid-annotation work such as arXiv 2402.12058, the lab
started attaching a temporary coordinate view of the rendered frame: a simple
grid with labeled regions and center dots. The grid is not part of the final
export. It exists only to give Gemma a shared spatial language for proposals
such as "move into the lower-left open grass" or "use the quiet sky above the
orange band." This matters because a small on-device model often understands
the scene semantically but struggles to map that understanding into stable
pixel coordinates. The scaffold turned vague spatial language into a more
concrete coordinate task without hard-coding a specific placement.

The second was counterintuitive: during correction, the model should not be
shown the fully rendered bad overlay as the main visual evidence. When Gemma saw
the actual sticker/text overlay on top of the image, it often rationalized the
previous choice, approved close calls, or focused on the typography rather than
the underlying subject obstruction. The better loop shows the clean frame plus a
temporary outline of the proposed overlay rectangle, along with the coordinate
scaffold and strict accept/move instructions. In other words, the correction
model judges "would this whole box cover the face, animal, hands, or story
evidence?" rather than being asked to admire or critique an already-designed
graphic. That reduced approval bias and made it easier for Gemma to propose a
new rectangle instead of defending the old one.

This does not mean Gemma should never see rendered artifacts. The lab still
keeps rendered outputs for scoring and human inspection, and thinking mode
remains enabled so the model can articulate its visual reasoning in diagnostic
traces. The important distinction is that correction-stage placement should be
based on a clean spatial decision aid, not on feeding the model the same flawed
composite and hoping it will self-correct.

## What Worked

### Strong positive case: side-subject image

For the ibis-in-bin image, the best recipes moved the overlay into the left-side free area instead of laying it across the bird.

Stable examples:

- Before: [baseline-think-on-fail.jpg](/tmp/aileen-overlay-selected-v2/IMG_0289/baseline-think-on-fail.jpg)
- After: [gemma-band-guarded-think-on-current.jpg](/tmp/aileen-overlay-selected-v2/IMG_0289/gemma-band-guarded-think-on-current.jpg)

### Scenic case: no clear subject

The new sunset image was useful because it has no obvious dominant subject. The band-guided path produced a simple horizon-area caption without forcing a subject-avoidance story onto the frame.

- [original.jpeg](/tmp/aileen-overlay-selected-v2/IMG_0312/original.jpeg)
- [gemma-band-guided-think-off-current.jpg](/tmp/aileen-overlay-selected-v2/IMG_0312/gemma-band-guided-think-off-current.jpg)

This suggests the geometric slot search plus measured layout is a good fit for scenic images.

### Token-budget sweet spot

One of the most surprising findings was that “more room for thinking” sometimes improved both quality and operational stability, but only up to a point.

- On the real iPad, `IMG_0289` at `4000` tokens was better than `1024` on wording and used fewer tool turns.
- On that same image, `8000` still completed, but it became more generic again.
- On `IMG_0533`, the budget effect was weaker and less favorable: `1024` stayed closer to the user story, while `4000` became slower, more editorialized, and more memory-hungry.
- On the simulator, the same two images showed the same qualitative pattern, which makes the effect less likely to be a pure device quirk.
- On harder close-up cases such as `IMG_7613`, higher budgets may also increase operational risk even when they improve reasoning room on easier images.

The right takeaway is not “always maximize the token cap.” The right takeaway is that thinking mode should be treated as a tunable budgeted subsystem, not a binary feature flag.

## What Still Fails

### Central subject cases remain hard

The quokka image is no longer a catastrophic failure in the stabilized path, but it is still the hardest taste case. The fresh-frame guarded recipe moved it from subject-hugging upper placement to a lower sticker band, which is much more acceptable, but still not consistently excellent across all central-subject images.

- Before: [baseline-think-on-fail.jpg](/tmp/aileen-overlay-selected-v2/IMG_7613/baseline-think-on-fail.jpg)
- Current hard case: [gemma-band-guarded-think-on-current.jpg](/tmp/aileen-overlay-selected-v2/IMG_7613/gemma-band-guarded-think-on-current.jpg)

This means the remaining problem is less about raw runtime reliability now and more about conservative subject extent estimation plus taste-aware scoring on E2B.

## Why These Choices Were Right

These technical choices were right for the hackathon constraints because they optimize for deployment reality rather than benchmark theater.

### They respect the on-device budget

We did not solve the problem by adding a heavier remote vision stack. We stayed on E2B and improved the interface, renderer, and conversation lifecycle around it.

### They reduce model burden where the model is weak

Gemma handles semantic and visual reasoning. Swift handles exact rendering and deterministic placement search. This is the correct boundary when the model has limited spatial precision.

### They make the system inspectable

Every run produces concrete prompts, tool calls, rendered outputs, and score artifacts. That makes engineering progress defensible in a writeup and easy to demonstrate in a video demo.

### They create a realistic path to productization

The same architecture can later absorb:

- better subject detectors
- stronger Gemma variants
- fine-tuning or preference optimization
- multi-candidate free-space ranking

without throwing away the native renderer or the tool-calling workflow.

## Current Best Recipe

At this point the best recipe is:

1. Compose the media first, then run Gemma 4 E2B on that rendered frame, not just on the raw source image.
2. Use thinking mode for both overlay generation and post-body generation.
3. Ask Gemma for a conservative subject keep-clear box and a coarse free-space patch rather than a perfect final overlay rectangle.
4. Convert that guidance into protected regions and let Swift own the final measured placement in guarded mode.
5. In correction passes, give Gemma a coordinate scaffold and clean-frame overlay outline so it can reason about the full proposed box without being biased by the already-rendered sticker.
6. Avoid feeding the bad composite overlay back as the primary correction image; use rendered composites for artifact inspection and scoring, not as the model's main self-correction evidence.
7. After each newly rendered frame, restart the Gemma conversation around that latest frame plus a compact task recap instead of carrying the full multimodal history forward.
8. Keep a one-shot full session rebuild retry as a safety fallback for LiteRT-LM.
9. Strip thought-channel text from visible app output and from any assistant history used for recovery, keeping thought traces only in the lab diagnostics.
10. Score overlap using rendered-image analysis, and penalize placements that crowd tall central subjects even when they technically miss the bbox.
11. Treat thinking/output token budget as a real quality-control parameter; a mid-range budget such as `4000` can be materially better than `1024` on some story-sensitive cases, but the optimum is image-dependent and should be treated as tunable rather than fixed dogma.

## Next Engineering Steps

The next iteration should focus on central-subject robustness:

1. Derive multiple candidate patches geometrically from the subject box, not just one.
2. Rank those patches in code by overlap margin, aspect ratio, and likely style fit.
3. Consider asking Gemma only for the subject box, then deriving all free-space patches natively.
4. If prompt and interface improvements plateau, prepare a small supervised fine-tuning set for placement guidance.

## Fine-Tuning Outlook

Fine-tuning is plausible, but it is not the first lever I would pull for the hackathon. The system still had clear interface and evaluation problems that were cheaper to fix in code. My current recommendation is:

- first stabilize the subject-box-plus-code-placement hybrid
- then collect curated examples of good and bad placements
- only after that decide whether SFT on Gemma E2B is worth the complexity

A practical path would be a curated overlay-placement dataset where each example includes:

- rendered frame
- subject keep-clear region
- good overlay patch
- chosen style
- final measured overlay parameters

## Session Outcome

This session changed the project from “Gemma guesses a top banner” into a credible on-device multimodal composition system with:

- real tool-calling
- shared rendering code
- an automation lab
- Gemma-guided placement experiments
- stable artifact generation
- partial but real success on difficult examples

The project is not done, but the engineering path is now clear and justified. The most defensible story for the hackathon is not that Gemma 4 was perfect out of the box. It is that Gemma 4, when paired with a carefully designed native tool interface and deterministic rendering core, can produce current-feeling on-device social visuals under real mobile constraints.
