#!/usr/bin/env python3
"""ONNX Runtime GenAI one-shot text generation runner.

Reads a JSON request from stdin and writes JSON response to stdout.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Any


def _fatal(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    sys.exit(code)


def _load_request() -> dict[str, Any]:
    try:
        payload = json.load(sys.stdin)
    except Exception as exc:  # noqa: BLE001
        _fatal(f"invalid_request_json: {exc}")
    if not isinstance(payload, dict):
        _fatal("invalid_request_json: payload must be a JSON object")
    return payload


def _resolve_model_root(model_path: str) -> str:
    model_root = Path(model_path)
    if model_root.is_file():
        # If a file path is provided (for example, genai_config.json), use its directory.
        model_root = model_root.parent

    genai_config = model_root / "genai_config.json"
    if genai_config.exists():
        return str(model_root)

    if (model_root / "config.json").exists():
        _fatal(f"genai_config_not_found_in_model_root: {model_root}")

    _fatal(f"model_root_not_found: {model_root}")
    return ""  # Unreachable, but keeps static checkers happy.


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


def main() -> None:
    request = _load_request()
    request_started = time.perf_counter()

    model_path = str(request.get("model_path", "")).strip()
    prompt = str(request.get("prompt", ""))
    max_new_tokens = int(request.get("max_new_tokens", 512))
    temperature = float(request.get("temperature", 0.2))
    top_p = float(request.get("top_p", 0.95))
    provider = request.get("provider")
    provider = str(provider) if provider is not None else None

    if not model_path:
        _fatal("missing_model_path")
    if not prompt:
        _fatal("missing_prompt")

    try:
        import onnxruntime_genai as og
    except Exception as exc:  # noqa: BLE001
        _fatal(f"onnxruntime_genai_import_failed: {exc}")

    try:
        config = og.Config(_resolve_model_root(model_path))
        _apply_provider(config, provider)

        model = og.Model(config)
        tokenizer = og.Tokenizer(model)
        formatted_prompt = _format_prompt(tokenizer, prompt)
        input_ids = tokenizer.encode(formatted_prompt)

        # ORT GenAI uses max_length (prompt + generated). Keep generation bounded.
        prompt_token_count = int(getattr(input_ids, "size", len(input_ids)))
        max_length = prompt_token_count + max(32, max_new_tokens)

        params = og.GeneratorParams(model)
        params.set_search_options(
            max_length=max_length,
            temperature=max(0.0, temperature),
            top_p=min(max(top_p, 0.0), 1.0),
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
    except Exception as exc:  # noqa: BLE001
        _fatal(f"onnxruntime_generation_failed: {exc}")

    generation_elapsed_s = max(generation_completed - generation_started, 0.0)
    total_elapsed_s = max(decode_completed - request_started, 0.0)
    ttft_ms = None
    if first_token_completed is not None:
        ttft_ms = (first_token_completed - generation_started) * 1000.0

    generated_tokens = output_token_count if output_token_count >= 0 else generated_token_steps
    tokens_per_second = (generated_tokens / generation_elapsed_s) if generation_elapsed_s > 0 else 0.0
    e2e_tokens_per_second = (generated_tokens / total_elapsed_s) if total_elapsed_s > 0 else 0.0

    json.dump(
        {
            "text": text,
            "metrics": {
                "prompt_tokens": prompt_token_count,
                "generated_tokens": generated_tokens,
                "total_tokens": prompt_token_count + generated_tokens,
                "ttft_ms": ttft_ms,
                "setup_latency_ms": max(generation_started - request_started, 0.0) * 1000.0,
                "generation_latency_ms": generation_elapsed_s * 1000.0,
                "decode_latency_ms": max(decode_completed - decode_started, 0.0) * 1000.0,
                "total_latency_ms": total_elapsed_s * 1000.0,
                "tokens_per_second": tokens_per_second,
                "e2e_tokens_per_second": e2e_tokens_per_second,
            },
        },
        sys.stdout,
    )


if __name__ == "__main__":
    main()
