# SenseAssist: Architecture Decisions, Challenges, and Major Builds

Date: 2026-03-04  
Scope analyzed: full repository (`Sources/`, `Tests/`, `Scripts/`, docs), git history, and local Codex thread transcripts for:
- `019ca82a-bdd3-77a1-a933-4e3aa561359b`
- `019cac49-e953-7c93-bd01-87d6b461a1c3`
- `019cadac-13e3-76f0-8ccb-afdf2db2c26a`
- `019cb0b2-bc2e-73f2-9fe8-68a778f03dd4`
- `019cb24b-5c32-7c02-8fd5-d61fbdced76a`

## 1) Major Architecture Decisions We Took

1. Local-first runtime and on-device LLM for live sync.
- Decision: live account sync requires local ONNX runtime path instead of cloud model dependency.
- Why: privacy, predictable cost, and deterministic deployment boundary.
- Evidence: commit `dea0b77`; `Sources/SenseAssistHelper/main.swift`; `Scripts/install_phi35_instruct_onnx.sh`.

2. Keep LLM as semantic engine; keep deterministic execution boundary for side effects.
- Decision: LLM proposes extraction/schedule/edit JSON, but code validates and controls writes.
- Why: reduce unsafe automation and malformed output risk.
- Evidence: `Sources/RulesEngine/RulesEngine.swift`; `Sources/LLMRuntime/LLMRuntime.swift`; `Sources/Ingestion/AutoPlanningService.swift`.

3. Managed calendar-only mutation policy.
- Decision: EventKit writes are constrained to managed calendar flow and managed markers.
- Why: avoid accidental mutation of unrelated user events.
- Evidence: `Sources/Integrations/EventKitAdapter/EventKitAdapter.swift`; `Sources/Orchestration/PlanCommandService.swift`.

4. Incremental provider sync with tuple cursors (`time + messageID`) and pagination.
- Decision: both Gmail and Outlook use stable cursor tie-break semantics and page traversal.
- Why: prevent dropped messages under same-timestamp bursts/high volume.
- Evidence: commits around `54096fa`; `Sources/Integrations/Gmail/GmailIntegration.swift`; `Sources/Integrations/Outlook/OutlookIntegration.swift`.

5. Multi-account as a first-class model.
- Decision: account-aware schema and account-scoped cursors/sources.
- Why: required for 3 Gmail + 1 Outlook operating mode.
- Evidence: migration `003_multi_account_support` in `Sources/Storage/SQLiteStore.swift`; account/cursor/task source repos in `Sources/Storage/Repositories.swift`.

6. Fault isolation across accounts.
- Decision: one failing account should not abort entire sync cycle.
- Why: improve real-world reliability and reduce full-run failures.
- Evidence: commit `2435ac8`; `Sources/Ingestion/MultiAccountSyncCoordinator.swift`; `Tests/IngestionTests/MultiAccountSyncCoordinatorTests.swift`.

7. Env-first credentials with optional keychain fallback.
- Decision: default to environment credentials, optional keychain chain via flag.
- Why: avoid keychain prompt loops and improve unattended operation.
- Evidence: commit `7e83af4`; `Sources/Auth/CredentialStore.swift`; `Sources/Auth/KeychainCredentialStore.swift`; `Sources/SenseAssistHelper/main.swift`.

8. Refresh-token based long-running auth.
- Decision: add refresh-token credential refresh for Gmail/Outlook.
- Why: avoid hourly access-token churn; improve “always-on” operation.
- Evidence: commits `940eef5`, `bd1c7e9`; `Sources/SenseAssistHelper/main.swift`.

9. Persisted audit/revision/operation model.
- Decision: store plan revisions and operations in SQLite for traceability and undo hydration.
- Why: auditable automation and safer rollback.
- Evidence: commit `b5924c7`; `Sources/Storage/Repositories.swift`; `Sources/Orchestration/PlanCommandService.swift`.

10. LLM schedule plan contract as core model.
- Decision: introduce `SchedulePlan` in shared contracts and route auto-planning through LLM schedule inference.
- Why: make scheduling API explicit and testable.
- Evidence: commits `ad7d67f`, `9c9f040`, `8236372`; `Sources/CoreContracts/Models.swift`; `Sources/LLMRuntime/LLMRuntime.swift`; `Sources/Ingestion/AutoPlanningService.swift`.

11. Shift from hybrid fallback to strict `llm_only` live scheduling.
- Decision: remove deterministic runtime fallback in active auto-planning path.
- Why: align system intent with LLM-first scheduling architecture.
- Evidence: commit range in thread `019cb0b2...`; `Sources/Ingestion/AutoPlanningService.swift`.

12. One repair re-prompt policy for LLM JSON reliability.
- Decision: 2 attempts total (initial + one repair prompt) for extraction and schedule outputs.
- Why: bound retry complexity while improving JSON contract success.
- Evidence: `maxAttempts = 2` in `Sources/LLMRuntime/LLMRuntime.swift`.

13. Pre-extraction triage stage (`actionable | maybe_actionable | ignore`).
- Decision: classify update intent before extraction and queue low-certainty items for review.
- Why: reduce inbox noise and false task creation.
- Evidence: `Sources/Ingestion/TaskIntentTriageEngine.swift`; ingestion services in `Sources/Ingestion/GmailIngestionService.swift` and `OutlookIngestionService.swift`.

14. `planner_input.json` snapshot as planning context contract.
- Decision: materialize one per-run planning snapshot and feed it to scheduling prompts.
- Why: planning consistency, auditability, and deterministic context capture.
- Evidence: commits `fc61ce5`, `50f8289`; `Sources/CoreContracts/PlannerInputSnapshot.swift`; `Sources/Ingestion/AutoPlanningService.swift`; `Sources/LLMRuntime/LLMRuntime.swift`.

15. Daily routine task injection as explicit planning policy.
- Decision: inject baseline student tasks (with env toggle).
- Why: enforce recurring student obligations in schedules.
- Evidence: `Sources/Ingestion/AutoPlanningService.swift`; tests in `Tests/IngestionTests/AutoPlanningServiceLLMTests.swift`.

16. Stable content hashing for updates.
- Decision: use SHA-256 hash for persisted update content hash.
- Why: deterministic dedupe/audit identity over process restarts.
- Evidence: commit `b5924c7`; `Sources/Storage/Repositories.swift`.

17. Adaptive scheduler state machine in helper loop.
- Decision: active/idle/error polling intervals with bounded jitter.
- Why: reduce unnecessary sync load and improve failure recovery behavior.
- Evidence: `Sources/Ingestion/AdaptiveSyncScheduler.swift`; helper loop in `Sources/SenseAssistHelper/main.swift`.

18. Treat benchmarking as first-class engineering artifact.
- Decision: instrument ONNX runner with latency/throughput metrics and automate benchmark reports.
- Why: quantify runtime viability and regressions.
- Evidence: commits `c171f5f`, `57ac197`; `Scripts/onnx_genai_runner.py`; `Scripts/onnx_benchmark.py`; `Scripts/benchmark_phi35_instruct_onnx.sh`.

19. Prefer warm ONNX runtime reuse over per-request cold starts.
- Decision: run ONNX runner in a persistent daemon mode and reuse loaded model/tokenizer across requests; keep one-shot fallback path for resilience.
- Why: reduce setup latency, reduce repeated model-load power cost, and improve end-to-end sync efficiency.
- Evidence: `Sources/LLMRuntime/LLMRuntime.swift`; `Scripts/onnx_genai_runner.py`; `Sources/SenseAssistHelper/main.swift`.

## 2) Core Challenges We Faced (and What We Did)

1. Risk of missed emails in incremental sync.
- Challenge: single-page fetch and weak cursor semantics could drop updates.
- Resolution: pagination + tuple cursor ordering and overlap-safe checks.

2. Keychain prompt loops / brittle auth behavior.
- Challenge: repeated keychain interactions and load errors disrupted live sync.
- Resolution: env-first lookup, optional non-interactive keychain, refresh-token flow.

3. ONNX model format mismatch (`genai_config.json` expectations).
- Challenge: not all downloaded ONNX repos matched ORT GenAI runner expectations.
- Resolution: model-root validation + installer/runtime guardrails; standardized Phi path.

4. LLM JSON contract reliability.
- Challenge: extraction/scheduling can return malformed JSON or miss required fields.
- Resolution: strict prompt schemas, decoding/materialization checks, one repair re-prompt.

5. Inbox noise causing weak task relevance.
- Challenge: direct extraction from all “approved” updates led to noisy tasks.
- Resolution: intent triage layer + review queue tagging for uncertain updates.

6. Multi-account reliability.
- Challenge: one account failure could collapse full sync cycle.
- Resolution: per-account failure capture and continuation semantics.

7. Architecture drift between docs, backlog, and implementation.
- Challenge: backlog/docs lagged behind actual changes.
- Resolution: repeated README and project documentation refreshes tied to code reality.

8. Need for measurable on-device performance proof.
- Challenge: no formal TTFT/tokens/s/latency instrumentation.
- Resolution: benchmark instrumentation and reproducible reports committed to repo.

9. Excessive per-request setup overhead in one-shot runtime path.
- Challenge: ONNX model and tokenizer were loaded for every inference call, inflating setup latency and power use.
- Resolution: introduced warm daemon mode with runtime reuse and operation-specific token caps to bound generation work.

## 3) Important Things We Built

1. End-to-end ingestion pipeline for Gmail and Outlook with account-level cursors.
2. Parser + confidence signals + triage routing before extraction.
3. LLM extraction + due-date repair + normalized task scheduling fields.
4. LLM schedule inference path with materialization checks and block validation.
5. `planner_input.json` contract and runtime injection into schedule prompts.
6. Auto-planning apply path with managed-calendar create/delete diff.
7. Slack `/plan` command parser and orchestration service (`today`, `add`, `move`, `undo`, `help`).
8. Persistent storage layer for updates/tasks/sources/accounts/cursors/revisions/operations/audit.
9. Credential chain and OAuth refresh lifecycle handling.
10. Adaptive background sync loop and health-check entrypoints.
11. Demo-mode tooling for safe local validation.
12. ONNX install/smoke/benchmark toolchain with reproducible metrics outputs.
13. Warm ONNX daemon transport with one-shot fallback and per-intent token budgets.

## 4) Thread-by-Thread Decisions and Outcomes

1. `019ca82a-bdd3-77a1-a933-4e3aa561359b` (2026-03-01 -> 2026-03-02)
- Established gap-first architecture audit and finalization plan.
- Drove key decisions around ONNX-only live path, sync correctness, auth hardening, and backlog framing.

2. `019cac49-e953-7c93-bd01-87d6b461a1c3` (2026-03-02 -> 2026-03-03)
- Executed heavy implementation and operational hardening:
  - model install/smoke path fixes,
  - auth refresh flow,
  - multi-account fault isolation,
  - LLM scheduling integration,
  - planner snapshot wiring,
  - documentation/productization updates.

3. `019cadac-13e3-76f0-8ccb-afdf2db2c26a` (2026-03-02)
- Consolidated cross-thread analysis into a detailed system report and decision synthesis.

4. `019cb0b2-bc2e-73f2-9fe8-68a778f03dd4` (2026-03-02 -> 2026-03-03)
- Refined LLM-centric pipeline:
  - routine task injection,
  - strict LLM planning stance,
  - architecture proposals around planning epochs/outbox ideas,
  - triage stage addition,
  - retry policy hardening.

5. `019cb24b-5c32-7c02-8fd5-d61fbdced76a` (2026-03-03)
- Added benchmark instrumentation and documented on-device model performance in README and project docs.

## 5) Open Architectural Gaps (Current State)

1. (Resolved on March 4, 2026) Menu app now ships a native menu-bar onboarding UI for permissions and account management.
2. Launch-at-login service lifecycle integration is still incomplete.
3. Planner still does not fully enforce all sleep-window semantics end-to-end.
4. SQLite encryption-at-rest is still pending.
5. Some persistence flows intentionally use `try?` and can suppress error visibility.
6. Full failure-matrix E2E coverage (provider outage/auth churn/EventKit edge cases) remains limited.

## 6) Primary Evidence Files

- Repo architecture and runtime:
  - `Sources/SenseAssistHelper/main.swift`
  - `Sources/Ingestion/AutoPlanningService.swift`
  - `Sources/LLMRuntime/LLMRuntime.swift`
  - `Sources/Storage/Repositories.swift`
  - `Sources/Integrations/Gmail/GmailIntegration.swift`
  - `Sources/Integrations/Outlook/OutlookIntegration.swift`
  - `Sources/Integrations/EventKitAdapter/EventKitAdapter.swift`
  - `Sources/Orchestration/PlanCommandService.swift`

- Test evidence:
  - `Tests/IngestionTests/*`
  - `Tests/StorageTests/StorageTests.swift`
  - `Tests/OrchestrationTests/PlanCommandServiceTests.swift`

- Thread transcripts used:
  - `~/.codex/sessions/2026/03/01/rollout-2026-03-01T01-51-39-019ca82a-bdd3-77a1-a933-4e3aa561359b.jsonl`
  - `~/.codex/sessions/2026/03/01/rollout-2026-03-01T21-04-10-019cac49-e953-7c93-bd01-87d6b461a1c3.jsonl`
  - `~/.codex/sessions/2026/03/02/rollout-2026-03-02T03-31-01-019cadac-13e3-76f0-8ccb-afdf2db2c26a.jsonl`
  - `~/.codex/sessions/2026/03/02/rollout-2026-03-02T17-37-09-019cb0b2-bc2e-73f2-9fe8-68a778f03dd4.jsonl`
  - `~/.codex/sessions/2026/03/03/rollout-2026-03-03T01-03-29-019cb24b-5c32-7c02-8fd5-d61fbdced76a.jsonl`
