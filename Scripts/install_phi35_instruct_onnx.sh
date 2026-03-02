#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_REPO_DEFAULT="microsoft/Phi-3.5-mini-instruct-onnx"
MODEL_DIR_DEFAULT="${ROOT_DIR}/Models/Phi-3.5-mini-instruct-onnx"
RUNNER_DEFAULT="${ROOT_DIR}/Scripts/onnx_genai_runner.py"
ENV_FILE_DEFAULT="${ROOT_DIR}/.env.onnx.local"
VENV_DIR_DEFAULT="${ROOT_DIR}/.venv-onnx"

MODEL_REPO="${MODEL_REPO_DEFAULT}"
MODEL_DIR="${MODEL_DIR_DEFAULT}"
PYTHON_BIN="${SENSEASSIST_ONNX_PYTHON:-python3}"
RUNNER_PATH="${SENSEASSIST_ONNX_RUNNER:-${RUNNER_DEFAULT}}"
ENV_FILE="${ENV_FILE_DEFAULT}"
VENV_DIR="${VENV_DIR_DEFAULT}"
SKIP_PIP_INSTALL=0
SKIP_DOWNLOAD=0

usage() {
  cat <<'USAGE'
Usage: Scripts/install_phi35_instruct_onnx.sh [options]

Options:
  --model-dir <path>   Destination folder for model files
  --repo <hf_repo>     Hugging Face repo ID (default: microsoft/Phi-3.5-mini-instruct-onnx)
  --python <path>      Python executable (default: python3 or SENSEASSIST_ONNX_PYTHON)
  --venv-dir <path>    Python virtualenv directory (default: .venv-onnx)
  --runner <path>      ONNX runner script path
  --env-file <path>    Output env file path
  --skip-pip-install   Skip pip dependency installation
  --skip-download      Skip Hugging Face model download
  -h, --help           Show this help
USAGE
}

resolve_runtime_model_dir() {
  local root="$1"

  if [[ -f "${root}/genai_config.json" ]]; then
    printf '%s\n' "${root}"
    return 0
  fi

  local chosen=""
  while IFS= read -r candidate; do
    local dir
    dir="$(dirname "${candidate}")"
    if [[ "${dir}" == *"/cpu_and_mobile/"* ]]; then
      printf '%s\n' "${dir}"
      return 0
    fi
    if [[ -z "${chosen}" ]]; then
      chosen="${dir}"
    fi
  done < <(find "${root}" -type f -name "genai_config.json" 2>/dev/null | sort)

  if [[ -n "${chosen}" ]]; then
    printf '%s\n' "${chosen}"
    return 0
  fi

  printf '%s\n' "${root}"
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model-dir)
      MODEL_DIR="$2"
      shift 2
      ;;
    --repo)
      MODEL_REPO="$2"
      shift 2
      ;;
    --python)
      PYTHON_BIN="$2"
      shift 2
      ;;
    --venv-dir)
      VENV_DIR="$2"
      shift 2
      ;;
    --runner)
      RUNNER_PATH="$2"
      shift 2
      ;;
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --skip-pip-install)
      SKIP_PIP_INSTALL=1
      shift
      ;;
    --skip-download)
      SKIP_DOWNLOAD=1
      shift
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

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "Python executable not found: ${PYTHON_BIN}" >&2
  exit 1
fi

HOST_PYTHON_PATH="$(command -v "${PYTHON_BIN}")"
PYTHON_PATH="${HOST_PYTHON_PATH}"

if [[ ! -f "${RUNNER_PATH}" ]]; then
  echo "ONNX runner script not found: ${RUNNER_PATH}" >&2
  exit 1
fi

mkdir -p "${MODEL_DIR}"
mkdir -p "$(dirname "${ENV_FILE}")"
mkdir -p "$(dirname "${VENV_DIR}")"

if [[ "${SKIP_PIP_INSTALL}" -eq 0 ]]; then
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    echo "Creating virtual environment at ${VENV_DIR}..."
    "${HOST_PYTHON_PATH}" -m venv "${VENV_DIR}"
  fi
  PYTHON_PATH="${VENV_DIR}/bin/python"
  echo "Installing Python dependencies..."
  "${PYTHON_PATH}" -m pip install --upgrade pip
  "${PYTHON_PATH}" -m pip install --upgrade "onnxruntime-genai>=0.4.0" "huggingface-hub>=0.27.0"
elif [[ -x "${VENV_DIR}/bin/python" ]]; then
  PYTHON_PATH="${VENV_DIR}/bin/python"
fi

if [[ "${SKIP_DOWNLOAD}" -eq 0 ]]; then
  echo "Downloading model ${MODEL_REPO} into ${MODEL_DIR}..."
  "${PYTHON_PATH}" - "${MODEL_REPO}" "${MODEL_DIR}" <<'PY'
import sys
from huggingface_hub import snapshot_download

repo = sys.argv[1]
target = sys.argv[2]

snapshot_download(
    repo_id=repo,
    local_dir=target,
    resume_download=True,
)
PY
fi

RUNTIME_MODEL_DIR="$(resolve_runtime_model_dir "${MODEL_DIR}")"

if [[ ! -f "${RUNTIME_MODEL_DIR}/genai_config.json" ]]; then
  echo "Model is not ORT GenAI-ready at ${RUNTIME_MODEL_DIR}: missing genai_config.json" >&2
  echo "Tip: choose a model/profile that ships genai_config.json (for example, a cpu_and_mobile sub-profile)." >&2
  exit 1
fi

cat > "${ENV_FILE}" <<EOF
export SENSEASSIST_ONNX_MODEL_PATH="${RUNTIME_MODEL_DIR}"
export SENSEASSIST_ONNX_RUNNER="${RUNNER_PATH}"
export SENSEASSIST_ONNX_PYTHON="${PYTHON_PATH}"
# Optional tuning:
# export SENSEASSIST_ONNX_PROVIDER="coreml"
# export SENSEASSIST_ONNX_MAX_NEW_TOKENS="512"
# export SENSEASSIST_ONNX_TEMPERATURE="0.2"
# export SENSEASSIST_ONNX_TOP_P="0.95"
EOF

echo "Wrote environment file: ${ENV_FILE}"
if [[ "${RUNTIME_MODEL_DIR}" != "${MODEL_DIR}" ]]; then
  echo "Resolved runtime model profile: ${RUNTIME_MODEL_DIR}"
fi
echo "Next steps:"
echo "  source \"${ENV_FILE}\""
echo "  make llm-smoke"
echo "  make sync-all-live"
