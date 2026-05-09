#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import shutil
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Any

import app as relay_app


def main() -> int:
    parser = argparse.ArgumentParser(description="Batch-run the Relay Desk production workflow without launching Gradio.")
    parser.add_argument("--dataset", type=Path, required=True, help="Dataset folder containing cases.csv, or a folder of image/story pairs.")
    parser.add_argument("--out", type=Path, required=True, help="Output directory for rendered images and results.jsonl.")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--background", default="")
    parser.add_argument("--dry-run", action="store_true", help="Validate case discovery without loading the model.")
    args = parser.parse_args()

    cases = discover_cases(args.dataset)
    if args.limit > 0:
        cases = cases[: args.limit]
    if not cases:
        raise SystemExit(f"No cases found under {args.dataset}")

    args.out.mkdir(parents=True, exist_ok=True)
    results_path = args.out / "results.jsonl"
    with results_path.open("w", encoding="utf-8") as handle:
        for case in cases:
            record = run_case(case, args.out, args.background, args.dry_run)
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
            handle.flush()

    print(results_path)
    return 0


def discover_cases(dataset: Path) -> list[dict[str, Any]]:
    manifest = dataset / "cases.csv"
    if manifest.exists():
        cases: list[dict[str, Any]] = []
        with manifest.open(newline="", encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                image_path = dataset / str(row.get("image_path") or "")
                if not image_path.exists():
                    continue
                story_text = str(row.get("story_text") or "").strip()
                story_path_raw = str(row.get("story_path") or "")
                story_path = dataset / story_path_raw if story_path_raw else image_path.with_suffix(".txt")
                if not story_text and story_path.exists():
                    story_text = story_path.read_text(encoding="utf-8").strip()
                cases.append(
                    {
                        "case_id": str(row.get("case_id") or image_path.stem),
                        "image_path": image_path,
                        "story_text": story_text,
                        "source_type": str(row.get("source_type") or "unknown"),
                    }
                )
        return cases

    cases = []
    for image_path in sorted(
        path
        for path in dataset.rglob("*")
        if path.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"} and "contact-sheet" not in path.name
    ):
        story_path = image_path.with_suffix(".txt")
        cases.append(
            {
                "case_id": image_path.stem,
                "image_path": image_path,
                "story_text": story_path.read_text(encoding="utf-8").strip() if story_path.exists() else "",
                "source_type": "unknown",
            }
        )
    return cases


def run_case(case: dict[str, Any], output_root: Path, background: str, dry_run: bool) -> dict[str, Any]:
    case_id = str(case["case_id"])
    image_path = Path(case["image_path"])
    record: dict[str, Any] = {
        "case_id": case_id,
        "input_path": str(image_path),
        "status": "planned" if dry_run else "error",
        "output_path": "",
        "tool_calls": [],
        "tool_payloads": [],
        "raw_responses": [],
        "thought_traces": [],
        "thinking_enabled": relay_app.ENABLE_THINKING,
        "error": "",
    }
    if dry_run:
        return record

    package = {"story": {"raw": str(case.get("story_text") or "")}}
    assets = [
        relay_app.ProductionAsset(
            tool_id="asset_1",
            path=str(image_path),
            display_name=image_path.name,
            kind="image",
            source_type=str(case.get("source_type") or "unknown"),
        )
    ]
    try:
        visual_result = relay_app.run_visual_workflow(package, assets, background)
        produced_path = output_root / f"{case_id}.jpg"
        shutil.copy2(visual_result.produced_path, produced_path)
        record.update(
            {
                "status": "success",
                "output_path": str(produced_path),
                "tool_calls": [asdict(call) for call in visual_result.tool_calls],
                "tool_payloads": visual_result.tool_payloads,
                "raw_responses": visual_result.raw_responses,
                "thought_traces": visual_result.thought_traces,
                "thinking_enabled": visual_result.thinking_enabled,
            }
        )
    except Exception as exc:
        record["error"] = str(exc)
    return record


if __name__ == "__main__":
    raise SystemExit(main())
