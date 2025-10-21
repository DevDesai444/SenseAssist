# SenseAssist Project Documentation (March 3, 2026)

## 1) Project Summary

SenseAssist is a local-first macOS assistant that ingests Gmail/Outlook updates, extracts tasks, builds feasible daily plans with an on-device LLM, and applies managed calendar mutations with auditability.

Core properties:
- Local-first processing for parsing/planning.
- Deterministic validation around LLM outputs before side effects.
- Revisioned operations for traceability/undo behavior.
- Multi-account ingestion and incremental cursor sync.

## 2) Repository Map

- `Sources/CoreContracts`: shared models/config/logging.
- `Sources/Storage`: SQLite bootstrap + repositories.
- `Sources/Ingestion`: Gmail/Outlook ingestion and orchestration.
- `Sources/ParserPipeline`: deterministic parsing and confidence signals.
- `Sources/LLMRuntime`: ONNX/Ollama runtime clients and prompt contracts.
- `Sources/Planner`: deterministic planner module for tests/tools.
- `Sources/Integrations`: Gmail/Outlook/Slack/EventKit adapters.
- `Sources/Orchestration`: command routing (`/plan`) and undo flow.
- `Sources/SenseAssistHelper`: helper/runtime entrypoint.
- `Tests`: module-level unit/integration test coverage.
- `Scripts`: model install, smoke check, and benchmark tooling.

## 3) Runtime Flow (High-Level)

1. Ingestion services pull Gmail/Outlook updates with per-account cursors.
2. Parser + LLM extraction converts updates to normalized `TaskItem`s.
3. Auto-planning builds `planner_input.json` snapshot and requests LLM schedule JSON.
4. Schedule output is validated (constraints/overlaps/time windows).
5. EventKit adapter applies managed calendar mutations.
6. Operation history is stored for audit and future rollback/undo.

## 4) On-Device Model Benchmark (Phi-3.5 ONNX)

Benchmark run date (UTC): `2026-03-03T06:14:56Z`  
Model profile: `Models/Phi-3.5-mini-instruct-onnx/cpu_and_mobile/cpu-int4-awq-block-128-acc-level-4`  
Runner: `Scripts/onnx_genai_runner.py`  
Suite: `standard` (`3` measured + `1` warmup per case)  
Measured runs: `9`

### 4.1 Core Results (Overall)

| Metric | Value |
| --- | ---: |
| Token Per Second (generation mean) | 10.36 tokens/s |
| Token Per Second (generation P95) | 13.22 tokens/s |
| Time to First Token (mean) | 0.56 ms |
| Time to First Token (P95) | 2.51 ms |
| Total Response Latency (mean) | 25,892.49 ms |
| Total Response Latency (P95) | 33,904.65 ms |
| Generation Latency (mean) | 14,820.02 ms |
| Setup Latency (mean) | 11,072.13 ms |
| End-to-End Throughput (mean) | 5.81 tokens/s |
| Mean Generated Tokens | 154.33 |

### 4.2 Per-Scenario Breakdown

| Case | Success | Mean TTFT (ms) | Mean Total Latency (ms) | Mean Tokens/s |
| --- | ---: | ---: | ---: | ---: |
| `json_contract_short` | 3/3 | 0.08 | 18,495.14 | 9.01 |
| `task_extraction_medium` | 3/3 | 1.42 | 26,787.67 | 12.05 |
| `schedule_planning_long` | 3/3 | 0.18 | 32,394.66 | 10.03 |

### 4.3 Benchmark Artifacts

- Markdown report: `Docs/ON_DEVICE_MODEL_BENCHMARK.md`
- Raw JSON: `Docs/ON_DEVICE_MODEL_BENCHMARK.json`

## 5) How To Re-run Benchmark

```bash
source ./.env.onnx.local
make llm-bench
```

Pinned output path example:

```bash
bash Scripts/benchmark_phi35_instruct_onnx.sh \
  --suite standard \
  --runs 3 \
  --warmup-runs 1 \
  --max-new-tokens 192 \
  --output-json Docs/ON_DEVICE_MODEL_BENCHMARK.json \
  --output-markdown Docs/ON_DEVICE_MODEL_BENCHMARK.md
```
