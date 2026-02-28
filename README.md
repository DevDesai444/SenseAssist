# SenseAssist

## Local Verification

Run all current verification checks in one command:

```bash
make status
```

Useful sub-commands:

```bash
make test
make helper-health
make sync-all-demo
make sync-all-live
make db-summary
```

## ONNX Runtime (On-Device LLM)

To run with ONNX Runtime GenAI instead of Ollama:

```bash
python3 -m pip install onnxruntime-genai
export SENSEASSIST_ONNX_MODEL_PATH="/absolute/path/to/onnx-model-dir"
export SENSEASSIST_ONNX_RUNNER="/Users/DEVDESAI1/Desktop/University_at_Buffalo/Projects/SenseAssist/Scripts/onnx_genai_runner.py"
export SENSEASSIST_ONNX_PYTHON="/usr/bin/python3"
make sync-all-live
```

Optional tuning:

```bash
export SENSEASSIST_ONNX_PROVIDER="coreml"     # cpu|coreml|cuda|dml
export SENSEASSIST_ONNX_MAX_NEW_TOKENS="512"
export SENSEASSIST_ONNX_TEMPERATURE="0.2"
export SENSEASSIST_ONNX_TOP_P="0.95"
```
