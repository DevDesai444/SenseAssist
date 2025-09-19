#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE_DEFAULT="${ROOT_DIR}/.env.onnx.local"
ENV_FILE="${ENV_FILE_DEFAULT}"

usage() {
  cat <<'USAGE'
Usage: Scripts/smoke_test_phi35_instruct_onnx.sh [--env-file <path>]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

if [[ -z "${SENSEASSIST_ONNX_MODEL_PATH:-}" ]]; then
  echo "SENSEASSIST_ONNX_MODEL_PATH is not set. Source ${ENV_FILE} or export it manually." >&2
  exit 1
fi

SENSEASSIST_ONNX_RUNNER="${SENSEASSIST_ONNX_RUNNER:-${ROOT_DIR}/Scripts/onnx_genai_runner.py}"
SENSEASSIST_ONNX_PYTHON="${SENSEASSIST_ONNX_PYTHON:-python3}"

if [[ ! -f "${SENSEASSIST_ONNX_RUNNER}" ]]; then
  echo "ONNX runner script not found: ${SENSEASSIST_ONNX_RUNNER}" >&2
  exit 1
fi

if ! command -v "${SENSEASSIST_ONNX_PYTHON}" >/dev/null 2>&1; then
  echo "Python executable not found: ${SENSEASSIST_ONNX_PYTHON}" >&2
  exit 1
fi

"${SENSEASSIST_ONNX_PYTHON}" - "${SENSEASSIST_ONNX_PYTHON}" "${SENSEASSIST_ONNX_RUNNER}" "${SENSEASSIST_ONNX_MODEL_PATH}" "${SENSEASSIST_ONNX_PROVIDER:-}" <<'PY'
import json
import re
import subprocess
import sys

python_bin = sys.argv[1]
runner = sys.argv[2]
model_path = sys.argv[3]
provider = sys.argv[4].strip()

prompt = (
    "You are a JSON-only assistant. "
    'Return exactly this object and nothing else: {"ok": true, "model": "ready"}'
)

request = {
    "model_path": model_path,
    "prompt": prompt,
    "max_new_tokens": 96,
    "temperature": 0.0,
    "top_p": 0.9,
}
if provider:
    request["provider"] = provider

proc = subprocess.run(
    [python_bin, runner],
    input=json.dumps(request).encode("utf-8"),
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)

if proc.returncode != 0:
    sys.stderr.write(proc.stderr.decode("utf-8", errors="replace"))
    raise SystemExit(proc.returncode)

try:
    payload = json.loads(proc.stdout.decode("utf-8"))
except Exception as exc:  # noqa: BLE001
    raise SystemExit(f"Runner output is not valid JSON: {exc}")

text = str(payload.get("text", "")).strip()
if not text:
    raise SystemExit("Runner returned empty text output.")

if "<think>" in text.lower():
    raise SystemExit("Model emitted <think> tags; this is not acceptable for strict JSON extraction path.")

match = re.search(r"\{.*\}", text, re.DOTALL)
if not match:
    raise SystemExit(f"Model output did not contain JSON object: {text[:240]}")

try:
    obj = json.loads(match.group(0))
except Exception as exc:  # noqa: BLE001
    raise SystemExit(f"Model JSON parse failed: {exc}; text={text[:240]}")

if obj.get("ok") is not True:
    raise SystemExit(f"Model JSON contract failed: {obj}")

preview = text.replace("\n", " ")[:200]
print("ONNX smoke test passed.")
print(f"Model response preview: {preview}")
PY
