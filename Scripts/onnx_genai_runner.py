#!/usr/bin/env python3
"""ONNX Runtime GenAI one-shot text generation runner.

Reads a JSON request from stdin and writes JSON response to stdout.
"""

from __future__ import annotations

import json
import sys
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


def _resolve_model_config_path(model_path: str) -> str:
    model_root = Path(model_path)
    if model_root.is_file():
        return str(model_root)

    preferred = model_root / "genai_config.json"
    if preferred.exists():
        return str(preferred)

    fallback = model_root / "config.json"
    if fallback.exists():
        return str(fallback)

    _fatal(f"model_config_not_found: {model_root}")
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


def main() -> None:
    request = _load_request()

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
        config = og.Config(_resolve_model_config_path(model_path))
        _apply_provider(config, provider)

        model = og.Model(config)
        tokenizer = og.Tokenizer(model)
        input_ids = tokenizer.encode(prompt)

        # ORT GenAI uses max_length (prompt + generated). Keep generation bounded.
        prompt_token_count = int(getattr(input_ids, "size", len(input_ids)))
        max_length = prompt_token_count + max(32, max_new_tokens)

        params = og.GeneratorParams(model)
        params.set_search_options(
            max_length=max_length,
            temperature=max(0.0, temperature),
            top_p=min(max(top_p, 0.0), 1.0),
        )
        params.set_model_input("input_ids", input_ids)

        generator = og.Generator(model, params)
        while not generator.is_done():
            generator.generate_next_token()

        output_ids = generator.get_sequence(0)
        text = tokenizer.decode(output_ids)
    except Exception as exc:  # noqa: BLE001
        _fatal(f"onnxruntime_generation_failed: {exc}")

    json.dump({"text": text}, sys.stdout)


if __name__ == "__main__":
    main()
