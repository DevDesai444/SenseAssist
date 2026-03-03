#!/usr/bin/env python3
"""Benchmark ONNX Runtime GenAI runner and write Markdown + JSON reports."""

from __future__ import annotations

import argparse
import json
import math
import shutil
import statistics
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from time import perf_counter
from typing import Any


@dataclass(frozen=True)
class BenchmarkCase:
    name: str
    description: str
    prompt: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Benchmark ONNX Runtime GenAI runner.")
    parser.add_argument("--runner", required=True, help="Path to Scripts/onnx_genai_runner.py")
    parser.add_argument("--python-bin", required=True, help="Python executable used to run the runner")
    parser.add_argument("--model-path", required=True, help="Path to ONNX Runtime GenAI model profile")
    parser.add_argument("--provider", default=None, help="Optional ONNX provider hint")
    parser.add_argument("--suite", choices=["quick", "standard"], default="standard")
    parser.add_argument("--warmup-runs", type=int, default=1)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--max-new-tokens", type=int, default=256)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--top-p", type=float, default=0.9)
    parser.add_argument("--output-json", default=None, help="Output JSON report path")
    parser.add_argument("--output-markdown", default=None, help="Output Markdown report path")
    parser.add_argument("--label", default="phi35_onnx_on_device", help="Benchmark label")
    return parser.parse_args()


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    sorted_values = sorted(values)
    if len(sorted_values) == 1:
        return sorted_values[0]

    rank = (len(sorted_values) - 1) * (p / 100.0)
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return sorted_values[lower]
    weight = rank - lower
    return sorted_values[lower] * (1.0 - weight) + sorted_values[upper] * weight


def metric_summary(values: list[float]) -> dict[str, float | None]:
    if not values:
        return {
            "count": 0,
            "min": None,
            "max": None,
            "mean": None,
            "stdev": None,
            "p50": None,
            "p90": None,
            "p95": None,
        }

    return {
        "count": len(values),
        "min": min(values),
        "max": max(values),
        "mean": statistics.fmean(values),
        "stdev": statistics.stdev(values) if len(values) > 1 else 0.0,
        "p50": percentile(values, 50.0),
        "p90": percentile(values, 90.0),
        "p95": percentile(values, 95.0),
    }


def format_float(value: float | None, digits: int = 2) -> str:
    if value is None:
        return "n/a"
    return f"{value:.{digits}f}"


def benchmark_cases(suite: str) -> list[BenchmarkCase]:
    cases = [
        BenchmarkCase(
            name="json_contract_short",
            description="Short deterministic JSON generation",
            prompt=(
                "You are a JSON-only assistant. "
                "Return exactly one JSON object with keys "
                '["task","priority","due_at_local","notes"] for this input: '
                '"Prepare CS quiz notes before Thursday 5 PM, medium priority."'
            ),
        ),
        BenchmarkCase(
            name="task_extraction_medium",
            description="Medium extraction-style prompt with multiple updates",
            prompt=(
                "Extract actionable tasks from these updates and return only a JSON array with fields "
                '["title","category","due_at_local","estimated_minutes","priority"]:\n'
                "1) CSE-331 Project Milestone 2 due Friday 11:59 PM.\n"
                "2) Internship application closes in 3 days, submit resume and cover letter.\n"
                "3) Quiz 4 announced for Monday; study chapters 6-8.\n"
                "4) Team sync moved to tomorrow 2 PM (meeting only, not a task)."
            ),
        ),
        BenchmarkCase(
            name="schedule_planning_long",
            description="Long planning-style prompt aligned to SenseAssist output format",
            prompt=(
                "Build a feasible day plan and return only a JSON object with fields "
                '["feasibility_state","unscheduled_task_ids","blocks"]. '
                "Constraints: day window 09:00-21:00 America/New_York, break every 90 minutes for 10 minutes, "
                "no overlap with locked blocks. Locked blocks: lecture 10:00-11:20, lab 15:00-16:20. "
                "Tasks: A) CSE331 project (task_id a1, 180 min, due in 6 days, priority 5). "
                "B) Internship application (task_id b2, 120 min, due in 2 days, priority 4). "
                "C) Quiz prep (task_id c3, 90 min, due in 1 day, priority 5). "
                "D) Routine practice (task_id d4, 60 min, priority 2)."
            ),
        ),
    ]
    if suite == "quick":
        return cases[:2]
    return cases


def run_one(
    *,
    python_bin: str,
    runner: str,
    request_payload: dict[str, Any],
) -> tuple[dict[str, Any] | None, str | None]:
    started = perf_counter()
    proc = subprocess.run(
        [python_bin, runner],
        input=json.dumps(request_payload).encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    finished = perf_counter()

    wall_latency_ms = (finished - started) * 1000.0
    if proc.returncode != 0:
        stderr_text = proc.stderr.decode("utf-8", errors="replace").strip()
        return None, f"runner_exit_{proc.returncode}: {stderr_text[:400]}"

    try:
        payload = json.loads(proc.stdout.decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        return None, f"runner_output_invalid_json: {exc}"

    text = str(payload.get("text", ""))
    metrics = payload.get("metrics", {})
    if not isinstance(metrics, dict):
        metrics = {}

    def metric(name: str) -> float | None:
        value = metrics.get(name)
        if value is None:
            return None
        try:
            return float(value)
        except Exception:  # noqa: BLE001
            return None

    total_latency_ms = metric("total_latency_ms")
    overhead_ms = None
    if total_latency_ms is not None:
        overhead_ms = wall_latency_ms - total_latency_ms

    return (
        {
            "text_preview": text.replace("\n", " ")[:240],
            "response_chars": len(text),
            "prompt_tokens": metric("prompt_tokens"),
            "generated_tokens": metric("generated_tokens"),
            "total_tokens": metric("total_tokens"),
            "ttft_ms": metric("ttft_ms"),
            "setup_latency_ms": metric("setup_latency_ms"),
            "generation_latency_ms": metric("generation_latency_ms"),
            "decode_latency_ms": metric("decode_latency_ms"),
            "total_latency_ms": total_latency_ms,
            "tokens_per_second": metric("tokens_per_second"),
            "e2e_tokens_per_second": metric("e2e_tokens_per_second"),
            "subprocess_wall_latency_ms": wall_latency_ms,
            "subprocess_overhead_ms": overhead_ms,
        },
        None,
    )


def default_output_paths() -> tuple[Path, Path]:
    now_local = datetime.now().astimezone()
    stamp = now_local.strftime("%Y%m%d_%H%M%S")
    out_dir = Path("Docs/benchmarks")
    return (
        out_dir / f"onnx_benchmark_{stamp}.json",
        out_dir / f"onnx_benchmark_{stamp}.md",
    )


def collect_metric(records: list[dict[str, Any]], key: str) -> list[float]:
    values: list[float] = []
    for record in records:
        value = record.get(key)
        if value is None:
            continue
        try:
            values.append(float(value))
        except Exception:  # noqa: BLE001
            continue
    return values


def build_markdown(
    *,
    report: dict[str, Any],
    json_path: Path,
) -> str:
    config = report["config"]
    overall = report["overall"]
    cases: list[dict[str, Any]] = report["cases"]

    lines: list[str] = []
    lines.append("# On-Device ONNX Model Benchmark Report")
    lines.append("")
    lines.append(f"- Generated at (UTC): `{report['generated_at_utc']}`")
    lines.append(f"- Label: `{config['label']}`")
    lines.append(f"- Model path: `{config['model_path']}`")
    lines.append(f"- Runner: `{config['runner']}`")
    lines.append(f"- Python: `{config['python_bin']}`")
    lines.append(f"- Provider: `{config['provider']}`")
    lines.append(
        f"- Runs: `{config['runs']}` measured + `{config['warmup_runs']}` warmup per case (`{config['suite']}` suite)"
    )
    lines.append(f"- Raw JSON: `{json_path}`")
    lines.append("")
    lines.append("## Core Metrics (per case)")
    lines.append("")
    lines.append(
        "| Case | Success | Mean TTFT (ms) | P95 TTFT (ms) | Mean Total Latency (ms) | P95 Total Latency (ms) | Mean Tokens/s | Mean E2E Tokens/s | Mean Output Tokens |"
    )
    lines.append(
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
    )
    for case in cases:
        summary = case["summary"]
        success = f"{summary['success_count']}/{summary['expected_count']}"
        lines.append(
            "| "
            + case["name"]
            + " | "
            + success
            + " | "
            + format_float(summary["ttft_ms"]["mean"])
            + " | "
            + format_float(summary["ttft_ms"]["p95"])
            + " | "
            + format_float(summary["total_latency_ms"]["mean"])
            + " | "
            + format_float(summary["total_latency_ms"]["p95"])
            + " | "
            + format_float(summary["tokens_per_second"]["mean"])
            + " | "
            + format_float(summary["e2e_tokens_per_second"]["mean"])
            + " | "
            + format_float(summary["generated_tokens"]["mean"])
            + " |"
        )

    lines.append("")
    lines.append("## Overall Aggregates")
    lines.append("")
    lines.append(
        "| Metric | Mean | P50 | P90 | P95 | Min | Max |"
    )
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for metric_key, label in [
        ("ttft_ms", "Time to first token (ms)"),
        ("total_latency_ms", "Total response latency (ms)"),
        ("generation_latency_ms", "Generation latency (ms)"),
        ("tokens_per_second", "Generation tokens/sec"),
        ("e2e_tokens_per_second", "End-to-end tokens/sec"),
        ("setup_latency_ms", "Model setup latency (ms)"),
        ("decode_latency_ms", "Decode latency (ms)"),
        ("subprocess_wall_latency_ms", "Subprocess wall latency (ms)"),
        ("subprocess_overhead_ms", "Subprocess overhead (ms)"),
        ("generated_tokens", "Generated tokens"),
    ]:
        stats = overall[metric_key]
        lines.append(
            "| "
            + label
            + " | "
            + format_float(stats["mean"])
            + " | "
            + format_float(stats["p50"])
            + " | "
            + format_float(stats["p90"])
            + " | "
            + format_float(stats["p95"])
            + " | "
            + format_float(stats["min"])
            + " | "
            + format_float(stats["max"])
            + " |"
        )

    lines.append("")
    lines.append("## Metric Definitions")
    lines.append("")
    lines.append("- `ttft_ms`: elapsed time from generation start until first generated token is available.")
    lines.append("- `tokens_per_second`: `generated_tokens / generation_latency` (decode excluded).")
    lines.append("- `total_latency_ms`: full runner request latency including setup + generation + decode.")
    lines.append("- `e2e_tokens_per_second`: `generated_tokens / total_latency`.")
    lines.append("- `subprocess_wall_latency_ms`: outer process wall time for each run (includes Python process overhead).")
    lines.append("- `subprocess_overhead_ms`: `subprocess_wall_latency_ms - total_latency_ms` (wrapper/process overhead estimate).")
    lines.append("")
    lines.append("## Notes")
    lines.append("")
    lines.append("- Values are from local on-device execution and depend on hardware, thermal state, and model/provider settings.")
    lines.append("- Warmup runs are excluded from reported summaries.")
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()

    if args.runs <= 0:
        print("--runs must be > 0", file=sys.stderr)
        return 2
    if args.warmup_runs < 0:
        print("--warmup-runs must be >= 0", file=sys.stderr)
        return 2

    runner = Path(args.runner).expanduser()
    if not runner.is_absolute():
        runner = (Path.cwd() / runner)
    runner = runner.resolve()

    python_bin_input = args.python_bin
    python_bin_path = Path(python_bin_input).expanduser()
    if python_bin_path.is_absolute() or "/" in python_bin_input:
        if not python_bin_path.is_absolute():
            python_bin_path = (Path.cwd() / python_bin_path)
        python_cmd = str(python_bin_path)
        python_exists = python_bin_path.exists()
    else:
        python_cmd = python_bin_input
        python_exists = shutil.which(python_cmd) is not None

    model_path = str(Path(args.model_path).expanduser().resolve())
    provider = args.provider if args.provider else "default"

    if not runner.exists():
        print(f"Runner not found: {runner}", file=sys.stderr)
        return 2
    if not python_exists:
        print(f"Python executable not found: {python_bin_input}", file=sys.stderr)
        return 2

    default_json, default_md = default_output_paths()
    output_json = Path(args.output_json) if args.output_json else default_json
    output_markdown = Path(args.output_markdown) if args.output_markdown else default_md
    output_json.parent.mkdir(parents=True, exist_ok=True)
    output_markdown.parent.mkdir(parents=True, exist_ok=True)

    cases = benchmark_cases(args.suite)
    expected_per_case = args.runs
    generated_at_utc = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")

    report: dict[str, Any] = {
        "generated_at_utc": generated_at_utc,
        "config": {
            "label": args.label,
            "suite": args.suite,
            "warmup_runs": args.warmup_runs,
            "runs": args.runs,
            "max_new_tokens": args.max_new_tokens,
            "temperature": args.temperature,
            "top_p": args.top_p,
            "model_path": model_path,
            "runner": str(runner),
            "python_bin": python_cmd,
            "python_bin_input": python_bin_input,
            "provider": provider,
            "host_platform": sys.platform,
            "host_python_version": sys.version.split()[0],
        },
        "cases": [],
        "overall": {},
    }

    overall_measured: list[dict[str, Any]] = []
    for case in cases:
        runs: list[dict[str, Any]] = []
        total_iterations = args.warmup_runs + args.runs
        for idx in range(total_iterations):
            is_warmup = idx < args.warmup_runs
            payload = {
                "model_path": model_path,
                "prompt": case.prompt,
                "max_new_tokens": args.max_new_tokens,
                "temperature": args.temperature,
                "top_p": args.top_p,
            }
            if args.provider:
                payload["provider"] = args.provider

            result, error = run_one(
                python_bin=python_cmd,
                runner=str(runner),
                request_payload=payload,
            )
            if error is not None:
                runs.append(
                    {
                        "run_index": idx + 1,
                        "warmup": is_warmup,
                        "ok": False,
                        "error": error,
                    }
                )
                continue

            assert result is not None
            run_record = {
                "run_index": idx + 1,
                "warmup": is_warmup,
                "ok": True,
                **result,
            }
            runs.append(run_record)
            if not is_warmup:
                overall_measured.append(run_record)

        measured = [run for run in runs if run.get("ok") and not run.get("warmup")]
        success_count = len(measured)
        case_summary = {
            "expected_count": expected_per_case,
            "success_count": success_count,
            "success_rate": (success_count / expected_per_case) if expected_per_case else 0.0,
            "ttft_ms": metric_summary(collect_metric(measured, "ttft_ms")),
            "setup_latency_ms": metric_summary(collect_metric(measured, "setup_latency_ms")),
            "generation_latency_ms": metric_summary(collect_metric(measured, "generation_latency_ms")),
            "decode_latency_ms": metric_summary(collect_metric(measured, "decode_latency_ms")),
            "total_latency_ms": metric_summary(collect_metric(measured, "total_latency_ms")),
            "tokens_per_second": metric_summary(collect_metric(measured, "tokens_per_second")),
            "e2e_tokens_per_second": metric_summary(collect_metric(measured, "e2e_tokens_per_second")),
            "subprocess_wall_latency_ms": metric_summary(collect_metric(measured, "subprocess_wall_latency_ms")),
            "subprocess_overhead_ms": metric_summary(collect_metric(measured, "subprocess_overhead_ms")),
            "generated_tokens": metric_summary(collect_metric(measured, "generated_tokens")),
            "prompt_tokens": metric_summary(collect_metric(measured, "prompt_tokens")),
            "total_tokens": metric_summary(collect_metric(measured, "total_tokens")),
        }

        report["cases"].append(
            {
                "name": case.name,
                "description": case.description,
                "runs": runs,
                "summary": case_summary,
            }
        )

    overall = {
        "ttft_ms": metric_summary(collect_metric(overall_measured, "ttft_ms")),
        "setup_latency_ms": metric_summary(collect_metric(overall_measured, "setup_latency_ms")),
        "generation_latency_ms": metric_summary(collect_metric(overall_measured, "generation_latency_ms")),
        "decode_latency_ms": metric_summary(collect_metric(overall_measured, "decode_latency_ms")),
        "total_latency_ms": metric_summary(collect_metric(overall_measured, "total_latency_ms")),
        "tokens_per_second": metric_summary(collect_metric(overall_measured, "tokens_per_second")),
        "e2e_tokens_per_second": metric_summary(collect_metric(overall_measured, "e2e_tokens_per_second")),
        "subprocess_wall_latency_ms": metric_summary(collect_metric(overall_measured, "subprocess_wall_latency_ms")),
        "subprocess_overhead_ms": metric_summary(collect_metric(overall_measured, "subprocess_overhead_ms")),
        "generated_tokens": metric_summary(collect_metric(overall_measured, "generated_tokens")),
        "prompt_tokens": metric_summary(collect_metric(overall_measured, "prompt_tokens")),
        "total_tokens": metric_summary(collect_metric(overall_measured, "total_tokens")),
        "total_measured_runs": len(overall_measured),
    }
    report["overall"] = overall

    output_json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    markdown = build_markdown(report=report, json_path=output_json)
    output_markdown.write_text(markdown, encoding="utf-8")

    print("ONNX benchmark complete.")
    print(f"JSON report: {output_json}")
    print(f"Markdown report: {output_markdown}")
    print(f"Measured runs: {overall['total_measured_runs']}")
    print(
        "Overall mean tokens/sec: "
        + format_float(overall["tokens_per_second"]["mean"])
    )
    print(
        "Overall mean TTFT (ms): "
        + format_float(overall["ttft_ms"]["mean"])
    )
    print(
        "Overall mean total latency (ms): "
        + format_float(overall["total_latency_ms"]["mean"])
    )

    if overall["total_measured_runs"] == 0:
        print("No successful measured runs.", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
