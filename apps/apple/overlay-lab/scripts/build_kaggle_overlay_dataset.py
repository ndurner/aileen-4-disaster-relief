#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    from PIL import Image
except ImportError as exc:
    raise SystemExit("Pillow is required. Install it with: python3 -m pip install Pillow") from exc


REPO_ROOT = Path(__file__).resolve().parents[4]
LAB_ROOT = REPO_ROOT / "apps" / "apple" / "overlay-lab"
DEFAULT_SOURCE = REPO_ROOT / "scratch" / "synthetic_testset"
DEFAULT_OUTPUT = Path("/tmp/aileen-kaggle-datasets/overlay-placement-benchmark")
GRADE_SCHEMA = LAB_ROOT / "schemas" / "codex_overlay_grade.schema.json"
CANVAS_SIZE = (1080, 1350)


@dataclass(frozen=True)
class CaseRecord:
    case_id: str
    source_image: Path
    source_story: Path
    image_path: str
    story_path: str
    story_text: str
    width: int
    height: int
    split: str
    source_type: str
    situation: str
    subject_focus: str
    keep_clear_hint: str


CONTROL_PLACEMENTS = [
    {
        "placement_id": "worst_top_banner",
        "description": "Known-bad upper sticker control that often collides with subject faces, hands, or working area.",
        "overlay_text": "Protecting new life after the storm.",
        "style": "sticker",
        "x": 220,
        "y": 135,
        "width": 640,
        "height": 220,
        "expected_grade": "fail_or_warn",
    },
    {
        "placement_id": "center_band",
        "description": "Middle-band control for detecting subject-obscuring compositions.",
        "overlay_text": "Protecting new life after the storm.",
        "style": "sticker",
        "x": 180,
        "y": 410,
        "width": 720,
        "height": 220,
        "expected_grade": "mixed",
    },
    {
        "placement_id": "lower_sticker",
        "description": "Lower sticker control that is often safer but still must be judged against field evidence and hands.",
        "overlay_text": "Protecting new life after the storm.",
        "style": "sticker",
        "x": 200,
        "y": 820,
        "width": 680,
        "height": 220,
        "expected_grade": "mixed_or_pass",
    },
]


SUBJECT_HINTS = {
    "seedling_guard": ("field volunteer and protected seedling", "Avoid the volunteer face/body, hands, mesh guard, seedling, and field tags."),
    "lizard_recovery_pen": ("lizard recovery pen, reptile shelter, and gloved hands", "Avoid the animal care enclosure, water dish, gloved hands, and clipboard area."),
    "shorebird_survey": ("volunteers, shorebirds, and shoreline survey markers", "Avoid volunteer bodies, birds, flags, binoculars, and survey evidence."),
    "wildlife_water_station": ("field worker, trough, water stream, and animal tracks", "Avoid the worker, water trough, pouring action, jerry cans, and visible tracks."),
    "track_camera_footprints": ("trail camera, footprints, ruler, notebook, and hands", "Avoid the camera, footprints, ruler, notebook, and gloved hands."),
    "frog_refuge_check": ("field worker, water trays, reeds, and test kit", "Avoid the worker, water-quality test area, trays, shade cloth, and refuge habitat."),
    "cockatoo_aviary_repair": ("cockatoos, carers, branches, perches, and tools", "Avoid bird faces/bodies, carers, branch placement, perches, bowls, and repair tools."),
    "possum_nest_box": ("worker on ladder, nest box, tree, rope, and drill", "Avoid the worker, ladder, nest box, rope attachment, drill, and safety gear."),
    "echidna_release": ("echidna, transport crate, carer hands, and field notes", "Avoid the echidna, crate opening, gloved hands, and release path."),
    "wallaby_joey_hydration": ("wallaby joey, carer hands, towel, hydration supplies", "Avoid the joey face/body, carer hands, towel, bottle/water supplies, and care station."),
}


def main() -> int:
    parser = argparse.ArgumentParser(description="Assemble a Kaggle-ready Aileen overlay-placement benchmark dataset.")
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--dataset-id",
        default=os.environ.get("AILEEN_KAGGLE_DATASET_ID", "YOUR_KAGGLE_USERNAME/aileen-overlay-placement-benchmark"),
        help="Kaggle dataset id in owner-slug/dataset-slug form.",
    )
    parser.add_argument("--title", default="Aileen Overlay Placement Benchmark")
    parser.add_argument("--license", default=os.environ.get("AILEEN_KAGGLE_LICENSE", "CC-BY-4.0"))
    parser.add_argument("--clean", action="store_true", help="Remove the output directory before rebuilding it.")
    args = parser.parse_args()

    if args.clean and args.out.exists():
        shutil.rmtree(args.out)
    args.out.mkdir(parents=True, exist_ok=True)

    cases = collect_cases(args.source, args.out)
    if not cases:
        raise SystemExit(f"No PNG cases with matching .txt stories found in {args.source}")

    copy_assets(cases, args.out)
    write_cases(cases, args.out)
    write_control_placements(cases, args.out)
    write_benchmark_config(args.out)
    write_readme(args.out, args.title, args.dataset_id, args.license, len(cases))
    write_kaggle_metadata(args.out, args.title, args.dataset_id, args.license, cases)
    write_upload_helper(args.out)

    print(args.out)
    return 0


def collect_cases(source: Path, output_root: Path) -> list[CaseRecord]:
    cases: list[CaseRecord] = []
    for image in sorted(source.glob("*.png")):
        story = image.with_suffix(".txt")
        if not story.exists():
            continue
        case_id = image.stem
        story_text = story.read_text(encoding="utf-8").strip()
        width, height = image_size(image)
        situation = story_text.split(".")[0].strip()
        focus, keep_clear = subject_hint(case_id)
        cases.append(
            CaseRecord(
                case_id=case_id,
                source_image=image,
                source_story=story,
                image_path=f"images/{image.name}",
                story_path=f"stories/{story.name}",
                story_text=story_text,
                width=width,
                height=height,
                split="test",
                source_type=source_type(case_id),
                situation=situation,
                subject_focus=focus,
                keep_clear_hint=keep_clear,
            )
        )
    return cases


def image_size(path: Path) -> tuple[int, int]:
    with Image.open(path) as image:
        return image.size


def subject_hint(case_id: str) -> tuple[str, str]:
    key = re.sub(r"^(SYN_ORIG_|SYN_|VAL_)", "", case_id)
    key = re.sub(r"^\d+_", "", key)
    return SUBJECT_HINTS.get(key, ("main subject and working area", "Avoid faces, bodies, hands, animals, tools, and field evidence."))


def source_type(case_id: str) -> str:
    if case_id.startswith("VAL_"):
        return "private_validation_photo_sanitized_png"
    if case_id.startswith("SYN_ORIG_"):
        return "synthetic_original_jpeg_sanitized_png"
    if case_id.startswith("SYN_"):
        return "synthetic_png_sanitized_png"
    return "sanitized_png"


def copy_assets(cases: list[CaseRecord], output_root: Path) -> None:
    image_root = output_root / "images"
    story_root = output_root / "stories"
    grader_root = output_root / "grader"
    image_root.mkdir(exist_ok=True)
    story_root.mkdir(exist_ok=True)
    grader_root.mkdir(exist_ok=True)
    for case in cases:
        shutil.copy2(case.source_image, output_root / case.image_path)
        shutil.copy2(case.source_story, output_root / case.story_path)
    if GRADE_SCHEMA.exists():
        shutil.copy2(GRADE_SCHEMA, grader_root / GRADE_SCHEMA.name)


def write_cases(cases: list[CaseRecord], output_root: Path) -> None:
    rows = [case_to_row(case) for case in cases]
    with (output_root / "cases.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    with (output_root / "cases.jsonl").open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def case_to_row(case: CaseRecord) -> dict[str, Any]:
    return {
        "case_id": case.case_id,
        "split": case.split,
        "image_path": case.image_path,
        "story_path": case.story_path,
        "width": case.width,
        "height": case.height,
        "source_type": case.source_type,
        "situation": case.situation,
        "story_text": case.story_text,
        "subject_focus": case.subject_focus,
        "keep_clear_hint": case.keep_clear_hint,
    }


def write_control_placements(cases: list[CaseRecord], output_root: Path) -> None:
    rows: list[dict[str, Any]] = []
    for case in cases:
        for placement in CONTROL_PLACEMENTS:
            rows.append(
                {
                    "case_id": case.case_id,
                    "canvas_width": CANVAS_SIZE[0],
                    "canvas_height": CANVAS_SIZE[1],
                    **placement,
                }
            )
    with (output_root / "control_placements.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def write_benchmark_config(output_root: Path) -> None:
    config = {
        "name": "aileen-overlay-placement-benchmark",
        "canvas": {"width": CANVAS_SIZE[0], "height": CANVAS_SIZE[1]},
        "task": "Render a short social overlay while keeping faces, animal bodies, hands, tools, and field evidence unobscured.",
        "primary_metric": "VLM judgment of whether overlay covers a face, animal, important subject, hands, or the main subject silhouette.",
        "accepted_grades": ["pass", "warn", "fail"],
        "recommended_backends": [
            "swift-fixture",
            "relay-fixture",
            "litert-ios",
            "transformers-relay",
        ],
        "grading_schema": "grader/codex_overlay_grade.schema.json",
        "control_placements": "control_placements.csv",
    }
    (output_root / "benchmark_config.json").write_text(json.dumps(config, indent=2), encoding="utf-8")


def write_readme(output_root: Path, title: str, dataset_id: str, license_name: str, case_count: int) -> None:
    readme = f"""# {title}

Kaggle dataset id target: `{dataset_id}`

This dataset is a compact benchmark for Aileen overlay-placement experiments. It contains {case_count} synthetic Australian wildlife disaster-recovery input images, paired story prompts, control placement rectangles, and a structured grading schema.

## Task

Given an input image and story context, produce a short Instagram-style text overlay on a 1080x1350 canvas without covering:

- human or animal faces
- important subject bodies or silhouettes
- hands performing field work
- tools, care supplies, animal tracks, field notes, nest boxes, guards, or other evidence central to the story

The benchmark is meant to compare prompt and tool-contract iterations across the iOS LiteRT-LM app path and the Gradio Relay Desk Transformers path.

## Files

- `cases.csv`: primary case manifest with image/story paths, dimensions, story text, subject focus, and keep-clear hints.
- `cases.jsonl`: the same case records in JSON Lines form.
- `images/`: active synthetic PNG source images. These are dataset payload files, not Kaggle cover-image metadata.
- `stories/`: matching story prompt sidecars.
- `control_placements.csv`: known-risk and safer control overlay rectangles on a 1080x1350 canvas.
- `benchmark_config.json`: shared benchmark settings for local harnesses and Kaggle notebooks.
- `grader/codex_overlay_grade.schema.json`: JSON schema for VLM-based placement grading.

## Provenance And Scope

The active images are synthetic PNG fixtures generated for local Aileen testing. The source repository expects embedded synthetic-media C2PA provenance on these files. This dataset intentionally excludes local private validation photos and large Gemma/LiteRT model files.

Kaggle supports these PNGs as normal dataset files in the upload folder. A file named `dataset-cover-image.png`, `dataset-cover-image.jpg`, `dataset-cover-image.jpeg`, or `dataset-cover-image.webp` would be treated separately as the dataset cover image; this package does not create one.

License metadata for this package is `{license_name}`. Confirm publishing rights for the generated media before making the Kaggle dataset public.

## Suggested Kaggle Notebook Flow

1. Load `cases.csv` and `control_placements.csv`.
2. Run each candidate backend or prompt strategy against each image/story pair.
3. Save rendered outputs and tool-call traces.
4. Grade each rendered output with a VLM using the supplied schema.
5. Report failure rate, warn rate, and examples where a strategy covers faces, animals, hands, or key field evidence.

## Local Harness

From the repository checkout, the local harness can consume this staged dataset:

```bash
services/relay-desk/.venv/bin/python \\
  apps/apple/overlay-lab/scripts/overlay_quality_harness.py \\
  --dataset /path/to/this/dataset \\
  --grade none
```
"""
    (output_root / "README.md").write_text(readme, encoding="utf-8")


def write_kaggle_metadata(output_root: Path, title: str, dataset_id: str, license_name: str, cases: list[CaseRecord]) -> None:
    resources: list[dict[str, Any]] = [
        {"path": "README.md", "description": "Dataset card and benchmark instructions."},
        {
            "path": "cases.csv",
            "description": "Primary case manifest.",
            "schema": {
                "fields": [
                    {"name": "case_id", "type": "string", "title": "Stable synthetic case id."},
                    {"name": "split", "type": "string", "title": "Benchmark split."},
                    {"name": "image_path", "type": "string", "title": "Relative path to the source image."},
                    {"name": "story_path", "type": "string", "title": "Relative path to the story sidecar."},
                    {"name": "width", "type": "integer", "title": "Source image width in pixels."},
                    {"name": "height", "type": "integer", "title": "Source image height in pixels."},
                    {"name": "source_type", "type": "string", "title": "Synthetic source/provenance expectation."},
                    {"name": "situation", "type": "string", "title": "Short disaster-recovery situation."},
                    {"name": "story_text", "type": "string", "title": "Full prompt story context."},
                    {"name": "subject_focus", "type": "string", "title": "Primary subject to keep visible."},
                    {"name": "keep_clear_hint", "type": "string", "title": "Human-readable keep-clear instruction."},
                ]
            },
        },
        {"path": "cases.jsonl", "description": "Case manifest in JSON Lines format."},
        {"path": "control_placements.csv", "description": "Known-risk and safer placement rectangles for renderer smoke tests."},
        {"path": "benchmark_config.json", "description": "Shared benchmark task and grading configuration."},
        {"path": "grader/codex_overlay_grade.schema.json", "description": "Structured VLM grading response schema."},
    ]
    resources.extend(
        {
            "path": case.image_path,
            "description": f"Synthetic source image for {case.case_id}: {case.situation}.",
        }
        for case in cases
    )
    metadata = {
        "title": title,
        "subtitle": "Synthetic wildlife disaster-response images for text-overlay placement benchmarking",
        "description": (
            "A compact benchmark for testing whether AI-assisted social-media overlay pipelines keep text off faces, "
            "animals, hands, tools, and other important subject regions. Built for the Aileen iOS LiteRT-LM and "
            "Gradio Relay Desk prompt/tool-contract iteration workflow."
        ),
        "id": dataset_id,
        "licenses": [{"name": license_name}],
        "keywords": ["image", "computer vision", "generative ai", "benchmark", "synthetic"],
        "resources": resources,
    }
    (output_root / "dataset-metadata.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")


def write_upload_helper(output_root: Path) -> None:
    helper = """#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v kaggle >/dev/null 2>&1; then
  echo "Install and configure the Kaggle CLI before publishing." >&2
  exit 1
fi

kaggle datasets create -p . --dir-mode zip
"""
    path = output_root / "publish_to_kaggle.sh"
    path.write_text(helper, encoding="utf-8")
    path.chmod(0o755)


if __name__ == "__main__":
    raise SystemExit(main())
