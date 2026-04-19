#!/usr/bin/env python3
import csv
import math
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Box:
    left: int
    top: int
    width: int
    height: int

    @property
    def right(self) -> int:
        return self.left + self.width

    @property
    def bottom(self) -> int:
        return self.top + self.height

    def padded(self, horizontal: int, vertical: int, max_width: int, max_height: int) -> "Box":
        left = max(self.left - horizontal, 0)
        top = max(self.top - vertical, 0)
        right = min(self.right + horizontal, max_width)
        bottom = min(self.bottom + vertical, max_height)
        return Box(left=left, top=top, width=max(1, right - left), height=max(1, bottom - top))

    def merge(self, other: "Box") -> "Box":
        left = min(self.left, other.left)
        top = min(self.top, other.top)
        right = max(self.right, other.right)
        bottom = max(self.bottom, other.bottom)
        return Box(left=left, top=top, width=right - left, height=bottom - top)


def image_size(path: Path) -> tuple[int, int]:
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height",
            "-of",
            "csv=p=0:s=x",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    width_text, height_text = result.stdout.strip().split("x")
    return int(width_text), int(height_text)


def detect_text_boxes(path: Path) -> list[Box]:
    with tempfile.TemporaryDirectory() as temp_dir:
        prefix = Path(temp_dir) / "ocr"
        ocr_input = Path(temp_dir) / "ocr-input.png"
        subprocess.run(
            ["magick", str(path), str(ocr_input)],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["tesseract", str(ocr_input), str(prefix), "tsv"],
            check=True,
            capture_output=True,
        )
        tsv_path = prefix.with_suffix(".tsv")
        rows = list(csv.DictReader(tsv_path.read_text(encoding="utf-8").splitlines(), delimiter="\t"))

    boxes: list[Box] = []
    for row in rows:
        text = (row.get("text") or "").strip()
        if not text:
            continue
        try:
            confidence = float(row.get("conf") or -1)
        except ValueError:
            confidence = -1
        if confidence < 35:
            continue

        width = int(row["width"])
        height = int(row["height"])
        if width < 18 or height < 12:
            continue

        boxes.append(
            Box(
                left=int(row["left"]),
                top=int(row["top"]),
                width=width,
                height=height,
            )
        )
    return boxes


def should_merge(lhs: Box, rhs: Box) -> bool:
    horizontal_gap = max(0, max(lhs.left, rhs.left) - min(lhs.right, rhs.right))
    vertical_gap = max(0, max(lhs.top, rhs.top) - min(lhs.bottom, rhs.bottom))
    line_height = max(lhs.height, rhs.height)
    return horizontal_gap <= max(28, int(line_height * 1.4)) and vertical_gap <= max(18, int(line_height * 0.8))


def merge_boxes(boxes: list[Box]) -> list[Box]:
    merged: list[Box] = []
    for box in sorted(boxes, key=lambda item: (item.top, item.left)):
        updated = False
        for index, existing in enumerate(merged):
            if should_merge(existing, box):
                merged[index] = existing.merge(box)
                updated = True
                break
        if not updated:
            merged.append(box)

    changed = True
    while changed:
        changed = False
        next_boxes: list[Box] = []
        while merged:
            current = merged.pop(0)
            merge_index = next((i for i, other in enumerate(merged) if should_merge(current, other)), None)
            if merge_index is None:
                next_boxes.append(current)
                continue
            current = current.merge(merged.pop(merge_index))
            merged.insert(0, current)
            changed = True
        merged = next_boxes
    return merged


def build_filter(boxes: list[Box]) -> str:
    filters = []
    previous = "[0:v]"
    for index, box in enumerate(boxes):
        target = f"[v{index}]"
        filters.append(
            f"{previous}delogo=x={box.left}:y={box.top}:w={box.width}:h={box.height}{target}"
        )
        previous = target
    return ";".join(filters), previous


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: remove_overlay_text_from_samples.py OUTPUT_DIR INPUT...", file=sys.stderr)
        return 2

    output_dir = Path(sys.argv[1])
    inputs = [Path(item) for item in sys.argv[2:]]
    output_dir.mkdir(parents=True, exist_ok=True)

    for input_path in inputs:
        width, height = image_size(input_path)
        boxes = merge_boxes(detect_text_boxes(input_path))
        padded = [
            box.padded(horizontal=max(10, math.ceil(box.height * 0.5)),
                       vertical=max(8, math.ceil(box.height * 0.35)),
                       max_width=width,
                       max_height=height)
            for box in boxes
        ]
        if not padded:
            output_path = output_dir / input_path.name
            output_path.write_bytes(input_path.read_bytes())
            print(f"{input_path.name}\t0\t{output_path}")
            continue

        filter_graph, tail = build_filter(padded)
        output_path = output_dir / input_path.name
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-i",
                str(input_path),
                "-filter_complex",
                filter_graph,
                "-map",
                tail,
                "-frames:v",
                "1",
                str(output_path),
            ],
            check=True,
            capture_output=True,
        )
        print(f"{input_path.name}\t{len(padded)}\t{output_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
