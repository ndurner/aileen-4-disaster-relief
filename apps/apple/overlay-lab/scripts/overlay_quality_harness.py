#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

try:
    from PIL import Image, ImageDraw, ImageFont, ImageOps
except ImportError:
    Image = ImageDraw = ImageFont = ImageOps = None  # type: ignore[assignment]


REPO_ROOT = Path(__file__).resolve().parents[4]
APPLE_ROOT = REPO_ROOT / "apps" / "apple"
LAB_ROOT = APPLE_ROOT / "overlay-lab"
SWIFT_LAB = LAB_ROOT / "scripts" / "overlay_lab.sh"
CODEX_SCHEMA = LAB_ROOT / "schemas" / "codex_overlay_grade.schema.json"
DEFAULT_DATASET = REPO_ROOT / "scratch" / "synthetic_testset"
DEFAULT_OUTPUT_ROOT = Path("/tmp/aileen-overlay-quality")
CANVAS_SIZE = (1080, 1350)
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png"}


@dataclass(frozen=True)
class OverlayStrategy:
    name: str
    text: str
    style: str
    x: int
    y: int
    width: int
    height: int
    top_fraction: float | None = None
    max_width_fraction: float | None = None
    target_line_count: int | None = None
    horizontal_anchor: str = "center"
    vertical_anchor: str = "top"


@dataclass(frozen=True)
class HarnessCase:
    case_id: str
    image_path: Path
    story_path: Path | None
    story: str


@dataclass
class HarnessResult:
    case_id: str
    backend: str
    strategy: str
    input_path: str
    output_path: str
    overlay_text: str
    style: str
    x: int
    y: int
    width: int
    height: int
    resolved_top_fraction: float
    resolved_center_x_fraction: float
    grade: str = "ungraded"
    overlay_covers_face_or_subject: bool | None = None
    overlay_quality: int | None = None
    reason: str = ""
    recommended_direction: str = ""


STRATEGIES: dict[str, OverlayStrategy] = {
    "worst-top": OverlayStrategy(
        name="worst-top",
        text="Protecting new life after the storm.",
        style="sticker",
        x=220,
        y=135,
        width=640,
        height=220,
    ),
    "center-band": OverlayStrategy(
        name="center-band",
        text="Protecting new life after the storm.",
        style="sticker",
        x=180,
        y=410,
        width=720,
        height=220,
    ),
    "lower-sticker": OverlayStrategy(
        name="lower-sticker",
        text="Protecting new life after the storm.",
        style="sticker",
        x=200,
        y=820,
        width=680,
        height=220,
    ),
}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run comparable overlay-placement cases across local renderers and optional Codex VLM grading."
    )
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument(
        "--backend",
        action="append",
        choices=["swift-fixture", "relay-fixture", "litert-ios", "transformers-relay"],
        help="Backend to run. May be repeated. Defaults to swift-fixture and relay-fixture.",
    )
    parser.add_argument(
        "--strategy",
        action="append",
        choices=sorted(STRATEGIES),
        help="Placement strategy to render. May be repeated. Defaults to worst-top and lower-sticker.",
    )
    parser.add_argument("--limit", type=int, default=0, help="Limit cases for a quick smoke run.")
    parser.add_argument("--grade", choices=["none", "codex"], default="none")
    parser.add_argument("--codex-model", default=os.environ.get("AILEEN_CODEX_GRADER_MODEL", "gpt-5.5"))
    parser.add_argument("--litert-timeout", type=int, default=900)
    parser.add_argument(
        "--relay-python",
        type=Path,
        default=Path(os.environ.get("AILEEN_RELAY_PYTHON", REPO_ROOT / "services" / "relay-desk" / ".venv" / "bin" / "python")),
        help="Python executable with Relay Desk dependencies for the transformers-relay backend.",
    )
    parser.add_argument("--relay-timeout", type=int, default=int(os.environ.get("AILEEN_RELAY_BATCH_TIMEOUT_SECONDS", "1800")))
    parser.add_argument("--relay-dry-run", action="store_true", help="Validate transformers-relay batch wiring without loading Gemma.")
    args = parser.parse_args()

    cases = discover_cases(args.dataset)
    if args.limit > 0:
        cases = cases[: args.limit]
    if not cases:
        raise SystemExit(f"No image cases found under {args.dataset}")

    backends = args.backend or ["swift-fixture", "relay-fixture"]
    strategies = [STRATEGIES[name] for name in (args.strategy or ["worst-top", "lower-sticker"])]
    run_dir = next_run_dir(args.out)
    render_dir = run_dir / "renders"
    render_dir.mkdir(parents=True, exist_ok=True)

    results: list[HarnessResult] = []
    for backend in backends:
        if backend == "litert-ios":
            run_litert_ios(cases, run_dir, args.litert_timeout)
            continue
        if backend == "transformers-relay":
            backend_results = run_transformers_relay(
                args.dataset,
                cases,
                run_dir,
                args.relay_python,
                args.relay_timeout,
                args.relay_dry_run,
            )
            if args.grade == "codex":
                case_by_id = {case.case_id: case for case in cases}
                for result in backend_results:
                    case = case_by_id.get(result.case_id)
                    if case:
                        apply_codex_grade(result, case, args.codex_model, run_dir)
            results.extend(backend_results)
            continue
        for case in cases:
            for strategy in strategies:
                result = render_case(backend, case, strategy, render_dir)
                if args.grade == "codex":
                    apply_codex_grade(result, case, args.codex_model, run_dir)
                results.append(result)

    write_results(
        run_dir,
        results,
        cases,
        backends,
        [strategy.name for strategy in strategies],
        args.grade,
        {
            "relay_dry_run": args.relay_dry_run,
            "relay_python": str(args.relay_python),
            "relay_timeout_seconds": args.relay_timeout,
        },
    )
    print(run_dir)
    return 0


def discover_cases(dataset: Path) -> list[HarnessCase]:
    manifest = dataset / "cases.csv"
    if manifest.exists():
        return discover_manifest_cases(dataset, manifest)

    image_paths = sorted(
        path
        for path in dataset.rglob("*")
        if path.suffix.lower() in IMAGE_SUFFIXES and "contact-sheet" not in path.name
    )
    cases: list[HarnessCase] = []
    for image_path in image_paths:
        story_path = image_path.with_suffix(".txt")
        story = story_path.read_text(encoding="utf-8").strip() if story_path.exists() else ""
        cases.append(
            HarnessCase(
                case_id=safe_case_id(image_path.relative_to(dataset)),
                image_path=image_path,
                story_path=story_path if story_path.exists() else None,
                story=story,
            )
        )
    return cases


def discover_manifest_cases(dataset: Path, manifest: Path) -> list[HarnessCase]:
    cases: list[HarnessCase] = []
    with manifest.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            image_path = dataset / str(row.get("image_path") or "")
            if not image_path.exists():
                continue
            story_path_raw = str(row.get("story_path") or "")
            story_path = dataset / story_path_raw if story_path_raw else image_path.with_suffix(".txt")
            story_text = str(row.get("story_text") or "").strip()
            if not story_text and story_path.exists():
                story_text = story_path.read_text(encoding="utf-8").strip()
            cases.append(
                HarnessCase(
                    case_id=str(row.get("case_id") or safe_case_id(image_path.relative_to(dataset))),
                    image_path=image_path,
                    story_path=story_path if story_path.exists() else None,
                    story=story_text,
                )
            )
    return cases


def safe_case_id(path: Path) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", str(path.with_suffix("")))


def next_run_dir(output_root: Path) -> Path:
    output_root.mkdir(parents=True, exist_ok=True)
    for index in range(1, 10_000):
        candidate = output_root / f"run-{index:04d}"
        if not candidate.exists():
            candidate.mkdir()
            return candidate
    raise RuntimeError(f"Unable to allocate run directory under {output_root}")


def render_case(backend: str, case: HarnessCase, strategy: OverlayStrategy, render_dir: Path) -> HarnessResult:
    output_dir = render_dir / backend / strategy.name / case.case_id
    output_dir.mkdir(parents=True, exist_ok=True)
    if backend == "swift-fixture":
        output_path, frame, style = render_swift(case, strategy, output_dir)
    elif backend == "relay-fixture":
        output_path, frame, style = render_relay(case, strategy, output_dir)
    else:
        raise ValueError(f"Unsupported direct backend: {backend}")
    x, y, width, height = frame
    return HarnessResult(
        case_id=case.case_id,
        backend=backend,
        strategy=strategy.name,
        input_path=str(case.image_path),
        output_path=str(output_path),
        overlay_text=strategy.text,
        style=style,
        x=x,
        y=y,
        width=width,
        height=height,
        resolved_top_fraction=y / CANVAS_SIZE[1],
        resolved_center_x_fraction=(x + width / 2) / CANVAS_SIZE[0],
    )


def render_swift(case: HarnessCase, strategy: OverlayStrategy, output_dir: Path) -> tuple[Path, tuple[int, int, int, int], str]:
    command = [
        str(SWIFT_LAB),
        "render",
        "--text",
        strategy.text,
        "--style",
        strategy.style,
        "--x",
        str(strategy.x),
        "--y",
        str(strategy.y),
        "--width",
        str(strategy.width),
        "--height",
        str(strategy.height),
        "--canvas",
        f"{CANVAS_SIZE[0]}x{CANVAS_SIZE[1]}",
        "--output-dir",
        str(output_dir),
        str(case.image_path),
    ]
    completed = subprocess.run(command, cwd=REPO_ROOT, check=True, text=True, capture_output=True)
    line = next((item for item in completed.stdout.splitlines() if item.startswith(str(output_dir))), "")
    match = re.search(r"^(.*?) style=([A-Za-z0-9_-]+) frame=(\d+),(\d+),(\d+),(\d+)", line)
    if not match:
        raise RuntimeError(f"Unable to parse Swift renderer output: {completed.stdout}")
    output_path = Path(match.group(1))
    style = match.group(2)
    frame = tuple(int(match.group(index)) for index in range(3, 7))
    return output_path, frame, style


def require_pillow() -> None:
    if Image is None or ImageDraw is None or ImageFont is None or ImageOps is None:
        raise SystemExit("Pillow is required for fixture rendering. Install it with: python3 -m pip install Pillow")


def render_relay(case: HarnessCase, strategy: OverlayStrategy, output_dir: Path) -> tuple[Path, tuple[int, int, int, int], str]:
    require_pillow()
    source = ImageOps.exif_transpose(Image.open(case.image_path)).convert("RGB")
    canvas = aspect_fill(source, CANVAS_SIZE)
    draw = ImageDraw.Draw(canvas, "RGBA")
    frame, style, wrapped, font = resolve_relay_overlay_frame(draw, strategy)
    box_x, box_y, box_width, box_height = frame
    if style == "tag":
        draw.rounded_rectangle((box_x, box_y, box_x + box_width, box_y + box_height), radius=20, fill=(20, 34, 38, 208))
        fill = (255, 255, 255, 255)
        pad_y = 18
    else:
        draw.rounded_rectangle((box_x, box_y, box_x + box_width, box_y + box_height), radius=32, fill=(252, 252, 248, 246))
        fill = (24, 28, 30, 255)
        pad_y = 30
    draw.multiline_text((CANVAS_SIZE[0] // 2, box_y + pad_y), wrapped, font=font, fill=fill, spacing=4, align="center", anchor="ma")
    output_path = output_dir / f"{case.image_path.stem}-{style}.jpg"
    canvas.save(output_path, quality=92)
    return output_path, frame, style


def aspect_fill(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    source_width, source_height = image.size
    target_width, target_height = size
    scale = max(target_width / max(source_width, 1), target_height / max(source_height, 1))
    resized = image.resize((int(source_width * scale), int(source_height * scale)), Image.Resampling.LANCZOS)
    left = max(0, (resized.width - target_width) // 2)
    top = max(0, (resized.height - target_height) // 2)
    return resized.crop((left, top, left + target_width, top + target_height))


def resolve_relay_overlay_frame(draw: ImageDraw.ImageDraw, strategy: OverlayStrategy) -> tuple[tuple[int, int, int, int], str, str, Any]:
    style = "tag" if strategy.style == "tag" or strategy.text.startswith("@") or (strategy.text.startswith("#") and len(strategy.text) < 32) else "sticker"
    font_size = 34 if style == "tag" else 58
    font = load_font(font_size)
    max_frame_width = int(clamp(strategy.width, CANVAS_SIZE[0] * 0.34, CANVAS_SIZE[0] * 0.78))
    top = strategy.y
    pad_x = 26 if style == "tag" else 46
    pad_y = 18 if style == "tag" else 30
    max_text_width = max(120, max_frame_width - (pad_x * 2))
    wrapped = wrap_overlay_text(strategy.text, font, max_text_width, 2)
    bbox = draw.multiline_textbbox((0, 0), wrapped, font=font, spacing=4, align="center")
    text_width = bbox[2] - bbox[0]
    text_height = bbox[3] - bbox[1]
    box_width = min(max_frame_width, text_width + pad_x * 2)
    box_height = text_height + pad_y * 2
    box_x = int((CANVAS_SIZE[0] - box_width) / 2)
    box_y = int(top)
    box_x = int(clamp(box_x, CANVAS_SIZE[0] * 0.04, CANVAS_SIZE[0] - box_width - CANVAS_SIZE[0] * 0.04))
    box_y = int(clamp(box_y, CANVAS_SIZE[1] * 0.08, CANVAS_SIZE[1] - box_height - CANVAS_SIZE[1] * 0.08))
    return (box_x, box_y, int(box_width), int(box_height)), style, wrapped, font


def load_font(size: int) -> Any:
    candidates = [
        "/System/Library/Fonts/Supplemental/Georgia Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/Library/Fonts/Arial Bold.ttf",
    ]
    for candidate in candidates:
        if Path(candidate).exists():
            return ImageFont.truetype(candidate, size=size)
    return ImageFont.load_default(size=size)


def wrap_overlay_text(text: str, font: Any, max_width: int, target_lines: int) -> str:
    words = text.split()
    if not words:
        return text
    lines = [""]
    measure = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    for word in words:
        candidate = f"{lines[-1]} {word}".strip()
        bbox = measure.textbbox((0, 0), candidate, font=font)
        if bbox[2] - bbox[0] <= max_width or not lines[-1]:
            lines[-1] = candidate
        else:
            lines.append(word)
    while len(lines) > max(target_lines, 1):
        shortest_index = min(range(len(lines) - 1), key=lambda index: len(lines[index]) + len(lines[index + 1]))
        lines[shortest_index : shortest_index + 2] = [f"{lines[shortest_index]} {lines[shortest_index + 1]}"]
    return "\n".join(lines)


def clamp(value: float, lower: float, upper: float) -> float:
    return min(max(value, lower), upper)


def apply_codex_grade(result: HarnessResult, case: HarnessCase, model: str, run_dir: Path) -> None:
    if not result.output_path or not Path(result.output_path).exists():
        result.grade = "warn"
        result.reason = result.reason or "No rendered output path available for Codex grading."
        return
    if shutil.which("codex") is None:
        result.grade = "warn"
        result.reason = "codex CLI not found"
        return
    grade_dir = run_dir / "codex-grades"
    grade_dir.mkdir(exist_ok=True)
    output_file = grade_dir / f"{result.backend}-{result.strategy}-{result.case_id}.json"
    prompt = codex_grade_prompt(result, case)
    command = [
        "codex",
        "exec",
        "--ephemeral",
        "--sandbox",
        "read-only",
        "-C",
        str(REPO_ROOT),
        "-m",
        model,
        "--output-schema",
        str(CODEX_SCHEMA),
        "-o",
        str(output_file),
        "-i",
        result.output_path,
        prompt,
    ]
    completed = subprocess.run(command, cwd=REPO_ROOT, text=True, capture_output=True)
    if completed.returncode != 0:
        result.grade = "warn"
        result.reason = f"codex grading failed: {completed.stderr.strip()[:400]}"
        return
    try:
        grade = json.loads(output_file.read_text(encoding="utf-8"))
    except Exception as exc:
        result.grade = "warn"
        result.reason = f"codex grade JSON parse failed: {exc}"
        return
    result.grade = str(grade.get("grade", "warn"))
    result.overlay_covers_face_or_subject = bool(grade.get("overlay_covers_face_or_subject"))
    result.overlay_quality = int(grade.get("overlay_quality", 0))
    result.reason = str(grade.get("reason", ""))
    result.recommended_direction = str(grade.get("recommended_direction", ""))


def codex_grade_prompt(result: HarnessResult, case: HarnessCase) -> str:
    return f"""
Grade this rendered social-media image for overlay placement only.

The overlay text is: {result.overlay_text!r}
The renderer reported the overlay box as x={result.x}, y={result.y}, width={result.width}, height={result.height} on a {CANVAS_SIZE[0]}x{CANVAS_SIZE[1]} canvas.
Source story context: {case.story or "No story text supplied."}

Fail if the overlay covers a visible human face, animal face, important subject body, hands doing meaningful work, or the main subject silhouette.
Warn if it is close enough to feel risky or visually clumsy.
Pass only when the overlay is clearly legible and placed in a visually defensible open area.

Return only JSON matching the supplied schema.
""".strip()


def run_litert_ios(cases: list[HarnessCase], run_dir: Path, timeout_seconds: int) -> None:
    input_dir = run_dir / "litert-inputs"
    input_dir.mkdir()
    for briefing_name in ("background_briefing.txt", "briefing.txt"):
        briefing_path = cases[0].image_path.parent / briefing_name if cases else None
        if briefing_path and briefing_path.exists():
            shutil.copy2(briefing_path, input_dir / briefing_name)
            break
    for case in cases:
        shutil.copy2(case.image_path, input_dir / case.image_path.name)
        if case.story_path:
            shutil.copy2(case.story_path, input_dir / f"{case.image_path.stem}.txt")
    image_inputs = sorted(path for path in input_dir.iterdir() if path.suffix.lower() in IMAGE_SUFFIXES)
    if not image_inputs:
        raise RuntimeError(f"No LiteRT image inputs staged under {input_dir}")
    env = os.environ.copy()
    env["AILEEN_GEMMA_LAB_OUT"] = str(run_dir / "litert-ios")
    env["AILEEN_GEMMA_LAB_TIMEOUT_SECONDS"] = str(timeout_seconds)
    subprocess.run([str(LAB_ROOT / "scripts" / "run_gemma_overlay_lab.sh"), *map(str, image_inputs)], cwd=REPO_ROOT, env=env, check=True)


def run_transformers_relay(
    dataset: Path,
    cases: list[HarnessCase],
    run_dir: Path,
    relay_python: Path,
    timeout_seconds: int,
    dry_run: bool,
) -> list[HarnessResult]:
    python_executable = relay_python if relay_python.exists() else Path(sys.executable)
    output_dir = run_dir / "renders" / "transformers-relay"
    output_dir.mkdir(parents=True, exist_ok=True)
    command = [
        str(python_executable),
        str(REPO_ROOT / "services" / "relay-desk" / "relay_batch.py"),
        "--dataset",
        str(dataset),
        "--out",
        str(output_dir),
    ]
    if len(cases) > 0:
        command.extend(["--limit", str(len(cases))])
    if dry_run:
        command.append("--dry-run")
    completed = subprocess.run(
        command,
        cwd=REPO_ROOT / "services" / "relay-desk",
        text=True,
        capture_output=True,
        timeout=timeout_seconds,
    )
    if completed.returncode != 0:
        return [
            HarnessResult(
                case_id=case.case_id,
                backend="transformers-relay",
                strategy="production-prompt",
                input_path=str(case.image_path),
                output_path="",
                overlay_text="",
                style="",
                x=0,
                y=0,
                width=0,
                height=0,
                resolved_top_fraction=0,
                resolved_center_x_fraction=0,
                grade="warn",
                reason=f"Relay batch failed: {(completed.stderr or completed.stdout).strip()[:500]}",
            )
            for case in cases
        ]

    results_path = output_dir / "results.jsonl"
    if not results_path.exists():
        return [
            HarnessResult(
                case_id=case.case_id,
                backend="transformers-relay",
                strategy="production-prompt",
                input_path=str(case.image_path),
                output_path="",
                overlay_text="",
                style="",
                x=0,
                y=0,
                width=0,
                height=0,
                resolved_top_fraction=0,
                resolved_center_x_fraction=0,
                grade="warn",
                reason="Relay batch completed without results.jsonl.",
            )
            for case in cases
        ]

    case_by_id = {case.case_id: case for case in cases}
    results: list[HarnessResult] = []
    with results_path.open(encoding="utf-8") as handle:
        for line in handle:
            record = json.loads(line)
            case_id = str(record.get("case_id") or "")
            case = case_by_id.get(case_id)
            payload = latest_overlay_payload(record.get("tool_payloads") or [])
            call = latest_overlay_call(record.get("tool_calls") or [])
            output_path = str(record.get("output_path") or "")
            status = str(record.get("status") or "")
            error = str(record.get("error") or "")
            x = int(payload.get("x") or 0)
            y = int(payload.get("y") or 0)
            width = int(payload.get("overlay_width") or 0)
            height = int(payload.get("overlay_height") or 0)
            canvas_width = int(payload.get("canvas_width") or CANVAS_SIZE[0])
            canvas_height = int(payload.get("canvas_height") or CANVAS_SIZE[1])
            results.append(
                HarnessResult(
                    case_id=case_id,
                    backend="transformers-relay",
                    strategy="production-prompt",
                    input_path=str(case.image_path if case else record.get("input_path") or ""),
                    output_path=output_path,
                    overlay_text=str(call.get("arguments", {}).get("overlay_text") or ""),
                    style=str(payload.get("style") or call.get("arguments", {}).get("style") or ""),
                    x=x,
                    y=y,
                    width=width,
                    height=height,
                    resolved_top_fraction=y / max(canvas_height, 1),
                    resolved_center_x_fraction=(x + width / 2) / max(canvas_width, 1),
                    grade="ungraded" if status == "success" else "warn",
                    reason=error or (f"Relay batch status: {status}." if status and status != "success" else ""),
                )
            )
    return results


def latest_overlay_payload(payloads: list[dict[str, Any]]) -> dict[str, Any]:
    for payload in reversed(payloads):
        if {"x", "y", "overlay_width", "overlay_height"} <= set(payload):
            return payload
    return {}


def latest_overlay_call(tool_calls: list[dict[str, Any]]) -> dict[str, Any]:
    for call in reversed(tool_calls):
        if call.get("name") in {"add_text_overlay", "move_text_overlay"}:
            return call
    return {}


def write_results(
    run_dir: Path,
    results: list[HarnessResult],
    cases: list[HarnessCase],
    backends: list[str],
    strategies: list[str],
    grade_mode: str,
    backend_options: dict[str, Any],
) -> None:
    result_strategies = sorted({result.strategy for result in results}) or strategies
    (run_dir / "manifest.json").write_text(
        json.dumps(
            {
                "cases": [
                    {
                        "case_id": case.case_id,
                        "image_path": str(case.image_path),
                        "story_path": str(case.story_path) if case.story_path else None,
                    }
                    for case in cases
                ],
                "backends": backends,
                "strategies": result_strategies,
                "grade": grade_mode,
                "backend_options": backend_options,
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    rows = [asdict(result) for result in results]
    (run_dir / "results.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
    if rows:
        with (run_dir / "results.csv").open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)


if __name__ == "__main__":
    raise SystemExit(main())
