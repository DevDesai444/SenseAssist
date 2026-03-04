#!/usr/bin/env python3
"""ONNX Runtime GenAI text generation runner.

Modes:
- One-shot (default): reads one JSON request from stdin and writes one JSON response.
- Daemon (`--daemon`): keeps model state warm and serves newline-delimited JSON requests.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


def _fatal(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    sys.exit(code)


class RunnerError(Exception):
    """Request-scoped errors that should not crash daemon mode."""


@dataclass
class RuntimeState:
    model_root: str | None = None
    provider_key: str | None = None
    model: Any = None
    tokenizer: Any = None


def _load_request() -> dict[str, Any]:
    try:
        payload = json.load(sys.stdin)
    except Exception as exc:  # noqa: BLE001
        raise RunnerError(f"invalid_request_json: {exc}") from exc
    if not isinstance(payload, dict):
        raise RunnerError("invalid_request_json: payload must be a JSON object")
    return payload


def _parse_request(payload: dict[str, Any]) -> dict[str, Any]:
    model_path = str(payload.get("model_path", "")).strip()
    prompt = str(payload.get("prompt", ""))
    max_new_tokens = int(payload.get("max_new_tokens", 512))
    temperature = float(payload.get("temperature", 0.2))
    top_p = float(payload.get("top_p", 0.95))
    provider = payload.get("provider")
    provider = str(provider) if provider is not None else None

    if not model_path:
        raise RunnerError("missing_model_path")
    if not prompt:
        raise RunnerError("missing_prompt")

    return {
        "model_path": model_path,
        "prompt": prompt,
        "max_new_tokens": max_new_tokens,
        "temperature": temperature,
        "top_p": top_p,
        "provider": provider,
    }


def _resolve_model_root(model_path: str) -> str:
    model_root = Path(model_path)
    if model_root.is_file():
        # If a file path is provided (for example, genai_config.json), use its directory.
        model_root = model_root.parent

    genai_config = model_root / "genai_config.json"
    if genai_config.exists():
        return str(model_root)

    if (model_root / "config.json").exists():
        raise RunnerError(f"genai_config_not_found_in_model_root: {model_root}")

    raise RunnerError(f"model_root_not_found: {model_root}")


def _apply_provider(config: Any, provider: str | None) -> None:
    if not provider:
        return

    normalized = provider.strip().lower()
    if not normalized:
        return

    provider_map = {
        "cpu": "CPUExecutionProvider",
        "cuda": "CUDAExecutionProvider",
        "directml": "DmlExecutionProvider",
        "dml": "DmlExecutionProvider",
        "coreml": "CoreMLExecutionProvider",
    }

    ep = provider_map.get(normalized, provider)
    config.clear_providers()
    config.append_provider(ep)


def _provider_key(provider: str | None) -> str:
    return (provider or "").strip().lower()


def _ensure_runtime(og: Any, state: RuntimeState, model_path: str, provider: str | None) -> tuple[bool, float]:
    resolved_model_root = _resolve_model_root(model_path)
    normalized_provider = _provider_key(provider)

    if (
        state.model is not None
        and state.tokenizer is not None
        and state.model_root == resolved_model_root
        and state.provider_key == normalized_provider
    ):
        return False, 0.0

    started = time.perf_counter()
    config = og.Config(resolved_model_root)
    _apply_provider(config, provider)
    model = og.Model(config)
    tokenizer = og.Tokenizer(model)
    finished = time.perf_counter()

    state.model_root = resolved_model_root
    state.provider_key = normalized_provider
    state.model = model
    state.tokenizer = tokenizer

    return True, max(finished - started, 0.0) * 1000.0


def _format_prompt(tokenizer: Any, prompt: str) -> str:
    apply_chat_template = getattr(tokenizer, "apply_chat_template", None)
    if apply_chat_template is None:
        return prompt

    try:
        messages = json.dumps([{"role": "user", "content": prompt}])
        return apply_chat_template(messages, add_generation_prompt=True)
    except Exception:
        # Fall back to raw prompt if the model/chat-template is not compatible.
        return prompt


def _generate_response(og: Any, state: RuntimeState, payload: dict[str, Any]) -> dict[str, Any]:
    request = _parse_request(payload)
    request_started = time.perf_counter()

    model_loaded_this_request, model_load_latency_ms = _ensure_runtime(
        og,
        state,
        request["model_path"],
        request["provider"],
    )

    model = state.model
    tokenizer = state.tokenizer
    if model is None or tokenizer is None:
        raise RunnerError("runtime_not_initialized")

    formatted_prompt = _format_prompt(tokenizer, request["prompt"])
    input_ids = tokenizer.encode(formatted_prompt)

    max_new_tokens = max(32, int(request["max_new_tokens"]))
    temperature = max(0.0, float(request["temperature"]))
    top_p = min(max(float(request["top_p"]), 0.0), 1.0)

    # ORT GenAI uses max_length (prompt + generated). Keep generation bounded.
    prompt_token_count = int(getattr(input_ids, "size", len(input_ids)))
    max_length = prompt_token_count + max_new_tokens

    params = og.GeneratorParams(model)
    params.set_search_options(
        max_length=max_length,
        temperature=temperature,
        top_p=top_p,
    )

    generator = og.Generator(model, params)
    generator.append_tokens(input_ids)

    generation_started = time.perf_counter()
    first_token_completed: float | None = None
    generated_token_steps = 0
    while not generator.is_done():
        generator.generate_next_token()
        generated_token_steps += 1
        if first_token_completed is None:
            first_token_completed = time.perf_counter()
    generation_completed = time.perf_counter()

    output_ids = generator.get_sequence(0)
    generated_ids = output_ids[prompt_token_count:]
    output_token_count = int(getattr(generated_ids, "size", len(generated_ids)))

    decode_started = time.perf_counter()
    text = tokenizer.decode(generated_ids)
    decode_completed = time.perf_counter()

    generation_elapsed_s = max(generation_completed - generation_started, 0.0)
    total_elapsed_s = max(decode_completed - request_started, 0.0)
    ttft_ms = None
    if first_token_completed is not None:
        ttft_ms = (first_token_completed - generation_started) * 1000.0

    generated_tokens = output_token_count if output_token_count >= 0 else generated_token_steps
    tokens_per_second = (generated_tokens / generation_elapsed_s) if generation_elapsed_s > 0 else 0.0
    e2e_tokens_per_second = (generated_tokens / total_elapsed_s) if total_elapsed_s > 0 else 0.0

    return {
        "text": text,
        "metrics": {
            "prompt_tokens": prompt_token_count,
            "generated_tokens": generated_tokens,
            "total_tokens": prompt_token_count + generated_tokens,
            "ttft_ms": ttft_ms,
            "model_load_latency_ms": model_load_latency_ms,
            "model_loaded_this_request": model_loaded_this_request,
            "setup_latency_ms": max(generation_started - request_started, 0.0) * 1000.0,
            "generation_latency_ms": generation_elapsed_s * 1000.0,
            "decode_latency_ms": max(decode_completed - decode_started, 0.0) * 1000.0,
            "total_latency_ms": total_elapsed_s * 1000.0,
            "tokens_per_second": tokens_per_second,
            "e2e_tokens_per_second": e2e_tokens_per_second,
        },
    }


def _emit_line(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")))
    sys.stdout.write("\n")
    sys.stdout.flush()


def _run_daemon() -> int:
    try:
        import onnxruntime_genai as og
    except Exception as exc:  # noqa: BLE001
        _emit_line({"error": f"onnxruntime_genai_import_failed: {exc}"})
        return 1

    state = RuntimeState()
    for line in sys.stdin:
        raw = line.strip()
        if not raw:
            continue

        try:
            payload = json.loads(raw)
        except Exception as exc:  # noqa: BLE001
            _emit_line({"error": f"invalid_request_json: {exc}"})
            continue

        if not isinstance(payload, dict):
            _emit_line({"error": "invalid_request_json: payload must be a JSON object"})
            continue

        if payload.get("cmd") == "shutdown":
            _emit_line({"ok": True})
            return 0

        try:
            _emit_line(_generate_response(og, state, payload))
        except RunnerError as exc:
            _emit_line({"error": str(exc)})
        except Exception as exc:  # noqa: BLE001
            _emit_line({"error": f"onnxruntime_generation_failed: {exc}"})

    return 0


def _run_one_shot() -> int:
    try:
        payload = _load_request()
        import onnxruntime_genai as og
    except RunnerError as exc:
        _fatal(str(exc))
    except Exception as exc:  # noqa: BLE001
        _fatal(f"onnxruntime_genai_import_failed: {exc}")
    else:
        try:
            response = _generate_response(og, RuntimeState(), payload)
        except RunnerError as exc:
            _fatal(str(exc))
        except Exception as exc:  # noqa: BLE001
            _fatal(f"onnxruntime_generation_failed: {exc}")

        json.dump(response, sys.stdout)
        return 0


def main() -> None:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--daemon", action="store_true", help="Run in long-lived JSONL daemon mode")
    args = parser.parse_args()

    if args.daemon:
        sys.exit(_run_daemon())

    sys.exit(_run_one_shot())


if __name__ == "__main__":
    main()
