from __future__ import annotations

import json
import mimetypes
import os
import re
import tempfile
import textwrap
import zipfile
from pathlib import Path
from typing import Any

import gradio as gr
import spaces
import torch
import yaml
from PIL import Image, ImageDraw, ImageFont, ImageOps
from transformers import AutoModelForMultimodalLM, AutoProcessor


APP_ROOT = Path(__file__).resolve().parent
SAMPLE_PACKAGE_PATH = APP_ROOT / "samples" / "aileen-job.yaml"
MODEL_ID = os.environ.get("AILEEN_RELAY_MODEL_ID", "google/gemma-4-E4B-it")
MAX_NEW_TOKENS = int(os.environ.get("AILEEN_RELAY_MAX_NEW_TOKENS", "900"))
GPU_SECONDS = int(os.environ.get("AILEEN_RELAY_GPU_SECONDS", "180"))
CANVAS_SIZE = (1080, 1350)

processor = AutoProcessor.from_pretrained(MODEL_ID)
model = AutoModelForMultimodalLM.from_pretrained(
    MODEL_ID,
    dtype="auto",
    device_map="auto",
)
model.eval()

OUTPUT_KEYS = ["overlay_text", "caption", "alt_text", "relay_note", "recipient_checklist"]
OPTIONAL_LAYOUT_KEYS = [
    "overlay_style",
    "overlay_top_fraction",
    "overlay_max_width_fraction",
    "overlay_target_line_count",
]

CSS = """
:root {
  --aileen-ink: #173943;
  --aileen-muted: #5f7780;
  --aileen-deep: #0d6a79;
  --aileen-reef: #57b8b8;
  --aileen-paper: rgba(255,255,255,0.82);
  --aileen-coral: #d97562;
}

.gradio-container {
  max-width: 1160px !important;
  margin: 0 auto !important;
  color: var(--aileen-ink);
  background:
    radial-gradient(circle at 10% 8%, rgba(87,184,184,0.22), transparent 32rem),
    linear-gradient(135deg, #f7fbfb 0%, #eaf6f5 58%, #fbf2e2 100%);
}

.aileen-hero {
  position: relative;
  overflow: hidden;
  border-radius: 24px;
  padding: 34px;
  min-height: 210px;
  background:
    linear-gradient(90deg, rgba(9,44,54,0.94), rgba(9,44,54,0.58)),
    radial-gradient(circle at 74% 25%, rgba(87,184,184,0.62), transparent 17rem),
    radial-gradient(circle at 78% 80%, rgba(245,202,139,0.46), transparent 18rem),
    #113f49;
  box-shadow: 0 20px 50px rgba(13,106,121,0.18);
}

.aileen-hero h1 {
  margin: 0 0 10px;
  color: white;
  font-size: clamp(2.1rem, 5vw, 4.4rem);
  line-height: 0.98;
  letter-spacing: 0;
}

.aileen-hero p {
  margin: 0;
  max-width: 680px;
  color: rgba(255,255,255,0.90);
  font-size: 1.05rem;
  line-height: 1.45;
}

.aileen-pill {
  display: inline-flex;
  align-items: center;
  color: #0f5966;
  background: rgba(255,255,255,0.76);
  border: 1px solid rgba(255,255,255,0.90);
  padding: 8px 12px;
  border-radius: 999px;
  font-weight: 700;
  font-size: 0.84rem;
  margin-bottom: 20px;
}

.aileen-card {
  border-radius: 18px;
  padding: 18px;
  background: var(--aileen-paper);
  border: 1px solid rgba(255,255,255,0.90);
  box-shadow: 0 14px 30px rgba(13,106,121,0.10);
}

.aileen-card h3 {
  margin: 0 0 10px;
  color: var(--aileen-ink);
  font-size: 1.12rem;
}

.aileen-small {
  color: var(--aileen-muted);
  font-size: 0.94rem;
  line-height: 1.45;
}

.aileen-small strong {
  color: var(--aileen-ink);
}

.aileen-warning {
  border-left: 4px solid var(--aileen-coral);
  padding: 12px 14px;
  border-radius: 12px;
  background: rgba(217,117,98,0.10);
  color: #68342c;
}

.aileen-ok {
  border-left: 4px solid var(--aileen-reef);
  padding: 12px 14px;
  border-radius: 12px;
  background: rgba(87,184,184,0.13);
  color: #174851;
}

button.primary {
  background: var(--aileen-deep) !important;
  border-color: var(--aileen-deep) !important;
}
"""


def load_sample_package() -> str:
    return SAMPLE_PACKAGE_PATH.read_text(encoding="utf-8")


def hero_html() -> str:
    return """
<section class="aileen-hero">
  <div class="aileen-pill">Trusted recipient desk</div>
  <h1>Aileen Relay Desk</h1>
  <p>
    Open the field package, attach the photos that came with it, and finish the
    public update while the responder can get back to the work.
  </p>
</section>
"""


def journey_html() -> str:
    return """
<div class="aileen-card">
  <h3>Desk handoff</h3>
  <p class="aileen-small">
    Desk Mode sends the field note and raw photos onward. This desk turns them
    into the story image, caption, alt text, relay note, and review package.
  </p>
</div>
"""


def uploaded_path(file_value: Any) -> str | None:
    if file_value is None:
        return None
    if isinstance(file_value, str):
        return file_value
    if isinstance(file_value, dict):
        return file_value.get("path") or file_value.get("name")
    return getattr(file_value, "name", None) or getattr(file_value, "path", None)


def read_package_text(pasted_text: str, package_file: Any) -> str:
    pasted_text = (pasted_text or "").strip()
    if pasted_text:
        return pasted_text
    path = uploaded_path(package_file)
    if path:
        return Path(path).read_text(encoding="utf-8")
    return load_sample_package()


def parse_package(package_text: str) -> tuple[dict[str, Any], str | None]:
    try:
        parsed = yaml.safe_load(package_text) or {}
    except yaml.YAMLError as exc:
        return {}, f"The package text could not be read: {exc}"
    if not isinstance(parsed, dict):
        return {}, "The package needs to be a field package."
    return parsed, None


def story_raw(package: dict[str, Any]) -> str:
    story = package.get("story") or {}
    if isinstance(story, dict):
        return str(story.get("raw") or story.get("post_body") or "").strip()
    return ""


def field_update(package: dict[str, Any]) -> dict[str, str]:
    raw = package.get("field_update") or {}
    if not isinstance(raw, dict):
        return {}
    return {str(key): str(value).strip() for key, value in raw.items() if value is not None}


def media_items(package: dict[str, Any]) -> list[dict[str, Any]]:
    raw = package.get("media") or []
    return raw if isinstance(raw, list) else []


def media_paths(media_files: list[Any] | None) -> list[str]:
    return [path for path in (uploaded_path(file) for file in (media_files or [])) if path]


def image_media_paths(media_files: list[Any] | None) -> list[str]:
    result = []
    for path in media_paths(media_files):
        mime_type, _ = mimetypes.guess_type(path)
        suffix = Path(path).suffix.lower()
        if (mime_type and mime_type.startswith("image/")) or suffix in {".jpg", ".jpeg", ".png", ".webp"}:
            result.append(path)
    return result


def package_summary(package: dict[str, Any], media_files: list[Any] | None) -> str:
    execution = package.get("execution") or {}
    mode = execution.get("mode", "remote_generate") if isinstance(execution, dict) else "remote_generate"
    update = field_update(package)
    media = media_items(package)
    uploaded_count = len(media_paths(media_files))

    parts = [
        '<div class="aileen-card">',
        "<h3>Field package</h3>",
        f'<p class="aileen-small"><strong>Status:</strong> {friendly_mode(str(mode))}</p>',
    ]
    if update.get("location_label"):
        parts.append(f'<p class="aileen-small"><strong>Place:</strong> {escape_html(update["location_label"])}</p>')
    if update.get("update_time_local"):
        parts.append(f'<p class="aileen-small"><strong>Time:</strong> {escape_html(update["update_time_local"])}</p>')
    parts.append(
        f'<p class="aileen-small"><strong>Media listed:</strong> {len(media)} - '
        f'<strong>attached here:</strong> {uploaded_count}</p>'
    )
    if update.get("safety_warning"):
        parts.append(f'<div class="aileen-warning">{escape_html(update["safety_warning"])}</div>')
    parts.append("</div>")
    return "\n".join(parts)


def friendly_mode(mode: str) -> str:
    if mode == "field_completed":
        return "Generated in the field; ready for review"
    if mode == "remote_generate":
        return "Needs desk completion"
    return mode.replace("_", " ")


def escape_html(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def build_generation_prompt(package: dict[str, Any], background_briefing: str) -> str:
    update = field_update(package)
    media = media_items(package)
    media_summary = "\n".join(
        f"- {item.get('id', 'media')}: {item.get('type', 'media')} ({item.get('source_type', 'unknown')})"
        for item in media
        if isinstance(item, dict)
    ) or "- no media manifest supplied"
    safety = update.get("safety_warning", "").strip()
    location = update.get("location_label", "").strip()
    update_time = update.get("update_time_local", "").strip()

    return f"""
Complete a disaster-response social update for a trusted recipient.

Use only the attached image, field package, and standing briefing. Do not invent
donation details, official affiliation, responder names, exact locations, route
details, private places, supply locations, urgent needs, or medical certainty.
Keep public location broad when the safety note asks for that.

Return strict JSON only. Do not wrap it in Markdown.

Required string fields:
- overlay_text: one short image label, no hashtags, no emoji.
- caption: one restrained public caption, one to three short paragraphs.
- alt_text: direct visual description for accessibility.
- relay_note: compact message suitable for a handoff note.
- recipient_checklist: short human review checklist.

Optional layout fields:
- overlay_style: "sticker" or "tag"; use "sticker" unless the label is a short handle-like tag.
- overlay_top_fraction: number from 0.18 to 0.76; prefer 0.62 to 0.72 for close central subjects.
- overlay_max_width_fraction: number from 0.44 to 0.78.
- overlay_target_line_count: 1, 2, or 3.

Standing briefing:
{background_briefing.strip() or "(not supplied)"}

Field note:
{story_raw(package) or "(not supplied)"}

Place:
{location or "(not supplied)"}

Time:
{update_time or "(not supplied)"}

Safety note:
{safety or "(none)"}

Media:
{media_summary}
""".strip()


def open_image(path: str) -> Image.Image:
    return ImageOps.exif_transpose(Image.open(path)).convert("RGB")


def generate_outputs(package: dict[str, Any], image_path: str, background_briefing: str) -> dict[str, str]:
    prompt = build_generation_prompt(package, background_briefing)
    image = open_image(image_path)
    messages = [
        {
            "role": "system",
            "content": "You are Aileen Relay Desk. Write factual, careful public updates from field packages.",
        },
        {
            "role": "user",
            "content": [
                {"type": "image", "image": image},
                {"type": "text", "text": prompt},
            ],
        },
    ]
    inputs = processor.apply_chat_template(
        messages,
        tokenize=True,
        return_dict=True,
        return_tensors="pt",
        add_generation_prompt=True,
        enable_thinking=False,
    ).to(model.device)
    input_len = inputs["input_ids"].shape[-1]

    with torch.inference_mode():
        generated_ids = model.generate(
            **inputs,
            max_new_tokens=MAX_NEW_TOKENS,
            do_sample=False,
        )

    generated_ids_trimmed = [
        out_ids[len(in_ids) :] for in_ids, out_ids in zip(inputs["input_ids"], generated_ids)
    ]
    raw_response = processor.batch_decode(
        generated_ids_trimmed,
        skip_special_tokens=False,
        clean_up_tokenization_spaces=False,
    )[0]
    candidates = [raw_response]
    if hasattr(processor, "parse_response"):
        parsed_response = processor.parse_response(raw_response)
        candidates.append(response_to_text(parsed_response))

    for candidate in candidates:
        parsed = parse_model_json(candidate)
        if parsed:
            return parsed
    raise gr.Error("The desk could not read the generated draft. Try once more with the same package.")


def response_to_text(response: Any) -> str:
    if isinstance(response, str):
        return response
    if isinstance(response, dict):
        for key in ["answer", "content", "text", "response"]:
            value = response.get(key)
            if isinstance(value, str):
                return value
        return json.dumps(response)
    if isinstance(response, list):
        return "\n".join(response_to_text(item) for item in response)
    return str(response)


def parse_model_json(text: str) -> dict[str, str] | None:
    text = text.strip()
    if not text:
        return None
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    if not text.startswith("{"):
        match = re.search(r"\{.*\}", text, flags=re.DOTALL)
        if not match:
            return None
        text = match.group(0)
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, dict):
        return None

    outputs = {key: str(parsed.get(key, "")).strip() for key in OUTPUT_KEYS}
    missing = [key for key in OUTPUT_KEYS if not outputs[key]]
    if missing:
        return None
    for key in OPTIONAL_LAYOUT_KEYS:
        value = parsed.get(key)
        if value is not None:
            outputs[key] = str(value).strip()
    return outputs


def render_story_visual(outputs: dict[str, str], image_path: str, package: dict[str, Any]) -> str:
    canvas = aspect_fill(open_image(image_path), CANVAS_SIZE)
    draw = ImageDraw.Draw(canvas, "RGBA")
    overlay_text = outputs["overlay_text"].strip()
    style = outputs.get("overlay_style", "sticker").strip()
    if style not in {"sticker", "tag"}:
        style = "sticker"

    font_size = 58 if style == "sticker" else 34
    font = load_font(font_size, bold=True)
    max_width_fraction = clamp(as_float(outputs.get("overlay_max_width_fraction"), 0.72), 0.44, 0.78)
    target_lines = int(clamp(as_float(outputs.get("overlay_target_line_count"), 2), 1, 3))
    max_text_width = int(CANVAS_SIZE[0] * max_width_fraction) - 92
    wrapped = wrap_overlay_text(overlay_text, font, max_text_width, target_lines)
    bbox = draw.multiline_textbbox((0, 0), wrapped, font=font, spacing=4, align="center")
    text_width = bbox[2] - bbox[0]
    text_height = bbox[3] - bbox[1]

    pad_x = 46 if style == "sticker" else 26
    pad_y = 30 if style == "sticker" else 18
    box_width = min(int(CANVAS_SIZE[0] * max_width_fraction), text_width + pad_x * 2)
    box_height = text_height + pad_y * 2
    top_fraction = clamp(as_float(outputs.get("overlay_top_fraction"), 0.68), 0.18, 0.76)
    box_x = int((CANVAS_SIZE[0] - box_width) / 2)
    box_y = int(CANVAS_SIZE[1] * top_fraction)
    if box_y + box_height > CANVAS_SIZE[1] - 92:
        box_y = CANVAS_SIZE[1] - box_height - 92

    if style == "sticker":
        draw.rounded_rectangle(
            (box_x, box_y, box_x + box_width, box_y + box_height),
            radius=32,
            fill=(252, 252, 248, 246),
        )
        fill = (24, 28, 30, 255)
    else:
        draw.rounded_rectangle(
            (box_x, box_y, box_x + box_width, box_y + box_height),
            radius=20,
            fill=(20, 34, 38, 208),
        )
        fill = (255, 255, 255, 255)

    draw.multiline_text(
        (CANVAS_SIZE[0] // 2, box_y + pad_y),
        wrapped,
        font=font,
        fill=fill,
        spacing=4,
        align="center",
        anchor="ma",
    )

    if package_uses_synthetic_media(package):
        provenance_font = load_font(26, bold=False)
        label = "Illustrative image"
        label_bbox = draw.textbbox((0, 0), label, font=provenance_font)
        label_width = label_bbox[2] - label_bbox[0] + 30
        label_height = label_bbox[3] - label_bbox[1] + 20
        label_x = CANVAS_SIZE[0] - label_width - 34
        label_y = 34
        draw.rounded_rectangle(
            (label_x, label_y, label_x + label_width, label_y + label_height),
            radius=16,
            fill=(20, 34, 38, 190),
        )
        draw.text(
            (label_x + 15, label_y + 10),
            label,
            font=provenance_font,
            fill=(255, 255, 255, 240),
        )

    output_dir = Path(tempfile.mkdtemp(prefix="aileen-relay-desk-visual-"))
    output_path = output_dir / "story-visual.jpg"
    canvas.save(output_path, quality=92)
    return str(output_path)


def aspect_fill(image: Image.Image, canvas_size: tuple[int, int]) -> Image.Image:
    image_ratio = image.width / max(image.height, 1)
    canvas_ratio = canvas_size[0] / canvas_size[1]
    if image_ratio > canvas_ratio:
        new_height = canvas_size[1]
        new_width = int(new_height * image_ratio)
    else:
        new_width = canvas_size[0]
        new_height = int(new_width / max(image_ratio, 0.01))
    image = image.resize((new_width, new_height), Image.Resampling.LANCZOS)
    left = (new_width - canvas_size[0]) // 2
    top = (new_height - canvas_size[1]) // 2
    return image.crop((left, top, left + canvas_size[0], top + canvas_size[1]))


def package_uses_synthetic_media(package: dict[str, Any]) -> bool:
    return any(
        isinstance(item, dict) and item.get("source_type") == "synthetic_demo_image"
        for item in media_items(package)
    )


def load_font(size: int, bold: bool):
    font_candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSerif-Bold.ttf"
        if bold
        else "/usr/share/fonts/truetype/liberation2/LiberationSerif-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/System/Library/Fonts/Supplemental/Georgia Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Georgia.ttf",
    ]
    for path in font_candidates:
        if Path(path).exists():
            return ImageFont.truetype(path, size=size)
    return ImageFont.load_default()


def wrap_overlay_text(text: str, font: Any, max_width: int, target_lines: int) -> str:
    measure = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = f"{current} {word}".strip()
        bbox = measure.textbbox((0, 0), candidate, font=font)
        if bbox[2] - bbox[0] <= max_width or not current:
            current = candidate
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    if len(lines) <= target_lines:
        return "\n".join(lines)

    kept = lines[:target_lines]
    kept[-1] = textwrap.shorten(kept[-1] + " " + " ".join(lines[target_lines:]), width=32, placeholder="...")
    return "\n".join(kept)


def as_float(value: str | None, default: float) -> float:
    try:
        return float(value) if value not in {None, ""} else default
    except ValueError:
        return default


def clamp(value: float, lower: float, upper: float) -> float:
    return max(lower, min(upper, value))


def output_markdown(outputs: dict[str, str]) -> str:
    return f"""
<div class="aileen-card">
  <h3>Public draft</h3>
  <p class="aileen-small">Review before publishing. Keep the responder's note close and do not add facts that are not in the package.</p>
</div>

### Image Label
{outputs["overlay_text"]}

### Caption
{outputs["caption"]}

### Alt Text
{outputs["alt_text"]}

### Relay Note
{outputs["relay_note"]}

### Recipient Check
{outputs["recipient_checklist"]}
"""


def create_output_zip(
    package_text: str,
    outputs: dict[str, str],
    media_file_paths: list[str],
    story_visual_path: str,
) -> str:
    workdir = Path(tempfile.mkdtemp(prefix="aileen-relay-desk-"))
    outputs_dir = workdir / "outputs"
    media_dir = workdir / "media"
    outputs_dir.mkdir(parents=True, exist_ok=True)
    media_dir.mkdir(parents=True, exist_ok=True)

    (workdir / "aileen-job.yaml").write_text(package_text.strip() + "\n", encoding="utf-8")
    artifact_names = {
        "overlay_text": "image-label.txt",
        "caption": "caption.txt",
        "alt_text": "alt-text.txt",
        "relay_note": "relay-note.txt",
        "recipient_checklist": "recipient-check.txt",
    }
    for key, filename in artifact_names.items():
        (outputs_dir / filename).write_text(outputs[key].strip() + "\n", encoding="utf-8")

    source_visual = Path(story_visual_path)
    (outputs_dir / "story-visual.jpg").write_bytes(source_visual.read_bytes())

    for path in media_file_paths:
        source = Path(path)
        if source.exists() and source.is_file():
            (media_dir / source.name).write_bytes(source.read_bytes())

    zip_path = workdir / "aileen-relay-desk-package.zip"
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for file_path in workdir.rglob("*"):
            if file_path == zip_path or file_path.is_dir():
                continue
            archive.write(file_path, file_path.relative_to(workdir))
    return str(zip_path)


@spaces.GPU(duration=GPU_SECONDS)
def complete_package(package_text: str, package_file: Any, media_files: list[Any] | None, background_briefing: str):
    full_text = read_package_text(package_text, package_file)
    package, error = parse_package(full_text)
    if error:
        raise gr.Error(error)

    image_paths = image_media_paths(media_files)
    if not image_paths:
        raise gr.Error("Attach the transferred photo before finishing the package.")

    all_media_paths = media_paths(media_files)
    outputs = generate_outputs(package, image_paths[0], background_briefing)
    story_visual_path = render_story_visual(outputs, image_paths[0], package)
    zip_path = create_output_zip(full_text, outputs, all_media_paths, story_visual_path)
    summary = package_summary(package, media_files)
    return summary, gr.update(value=story_visual_path, visible=True), output_markdown(outputs), zip_path


with gr.Blocks(css=CSS, title="Aileen Relay Desk") as demo:
    gr.HTML(hero_html())
    gr.HTML(journey_html())

    with gr.Row():
        with gr.Column(scale=5):
            with gr.Group():
                gr.Markdown("### Field Package")
                package_file = gr.File(
                    label="Upload package file",
                    file_count="single",
                    file_types=[".yaml", ".yml", ".txt"],
                )
                package_text = gr.Textbox(
                    label="Or paste package text",
                    value=load_sample_package(),
                    lines=14,
                    max_lines=24,
                    placeholder="Paste the package text copied from the field app.",
                )
                media_files = gr.File(
                    label="Attach photos",
                    file_count="multiple",
                    file_types=[".png", ".jpg", ".jpeg", ".webp"],
                )
                background_briefing = gr.Textbox(
                    label="Standing briefing",
                    lines=5,
                    placeholder="Optional field-team context copied separately when needed.",
                )
                with gr.Row():
                    sample_button = gr.Button("Load sample", variant="secondary")
                    complete_button = gr.Button("Finish package", variant="primary")

        with gr.Column(scale=4):
            package_summary_html = gr.HTML(
                '<div class="aileen-card"><h3>Ready</h3><p class="aileen-small">Load a package, attach the transferred photos, then finish the desk draft.</p></div>'
            )
            story_visual = gr.Image(label="Story visual", type="filepath", height=560, visible=False)

    gr.Markdown("## Finished Update")
    output = gr.Markdown()
    zip_file = gr.File(label="Download final package")

    sample_button.click(fn=load_sample_package, outputs=package_text)
    complete_button.click(
        fn=complete_package,
        inputs=[package_text, package_file, media_files, background_briefing],
        outputs=[package_summary_html, story_visual, output, zip_file],
    )


if __name__ == "__main__":
    demo.queue(max_size=16).launch()
