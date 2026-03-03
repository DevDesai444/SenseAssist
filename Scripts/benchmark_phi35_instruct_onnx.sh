#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE_DEFAULT="${ROOT_DIR}/.env.onnx.local"
ENV_FILE="${ENV_FILE_DEFAULT}"
FORWARD_ARGS=()

usage() {
  cat <<'USAGE'
Usage: Scripts/benchmark_phi35_instruct_onnx.sh [--env-file <path>] [benchmark args...]

Runs ONNX benchmark suite and writes Markdown + JSON reports.
Benchmark args are passed through to Scripts/onnx_benchmark.py.

Common benchmark args:
  --suite quick|standard
  --runs <int>
  --warmup-runs <int>
  --max-new-tokens <int>
  --output-markdown <path>
  --output-json <path>
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
      FORWARD_ARGS+=("$1")
      shift
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
BENCHMARK_SCRIPT="${ROOT_DIR}/Scripts/onnx_benchmark.py"

if [[ ! -f "${SENSEASSIST_ONNX_RUNNER}" ]]; then
  echo "ONNX runner script not found: ${SENSEASSIST_ONNX_RUNNER}" >&2
  exit 1
fi

if [[ ! -f "${BENCHMARK_SCRIPT}" ]]; then
  echo "Benchmark script not found: ${BENCHMARK_SCRIPT}" >&2
  exit 1
fi

if ! command -v "${SENSEASSIST_ONNX_PYTHON}" >/dev/null 2>&1; then
  echo "Python executable not found: ${SENSEASSIST_ONNX_PYTHON}" >&2
  exit 1
fi

DEFAULT_ARGS=()
if [[ -n "${SENSEASSIST_ONNX_PROVIDER:-}" ]]; then
  DEFAULT_ARGS+=(--provider "${SENSEASSIST_ONNX_PROVIDER}")
fi
if [[ -n "${SENSEASSIST_ONNX_MAX_NEW_TOKENS:-}" ]]; then
  DEFAULT_ARGS+=(--max-new-tokens "${SENSEASSIST_ONNX_MAX_NEW_TOKENS}")
fi
if [[ -n "${SENSEASSIST_ONNX_TEMPERATURE:-}" ]]; then
  DEFAULT_ARGS+=(--temperature "${SENSEASSIST_ONNX_TEMPERATURE}")
fi
if [[ -n "${SENSEASSIST_ONNX_TOP_P:-}" ]]; then
  DEFAULT_ARGS+=(--top-p "${SENSEASSIST_ONNX_TOP_P}")
fi

COMMAND=(
  "${SENSEASSIST_ONNX_PYTHON}"
  "${BENCHMARK_SCRIPT}"
  --python-bin "${SENSEASSIST_ONNX_PYTHON}"
  --runner "${SENSEASSIST_ONNX_RUNNER}"
  --model-path "${SENSEASSIST_ONNX_MODEL_PATH}"
)

if [[ ${#DEFAULT_ARGS[@]} -gt 0 ]]; then
  COMMAND+=("${DEFAULT_ARGS[@]}")
fi
if [[ ${#FORWARD_ARGS[@]} -gt 0 ]]; then
  COMMAND+=("${FORWARD_ARGS[@]}")
fi

"${COMMAND[@]}"
