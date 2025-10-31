# SenseAssist Developer Onboarding Report

Date: March 4, 2026  
Audience: new engineer joining the SenseAssist codebase

## 1) Why This Project Exists

SenseAssist is a local-first macOS assistant for students.

Primary job:
- ingest email updates (Gmail + Outlook)
- extract actionable work
- build a feasible daily plan with an on-device LLM
- apply only managed, auditable calendar changes

Core product goal:
- reduce planning overhead and missed deadlines while preserving user control and traceability.

Core engineering goal:
- keep semantic intelligence in the LLM, but keep all side effects behind deterministic validation and storage-backed audit trails.

## 2) Product Objectives and Constraints

Objectives:
- Privacy-first operation: planning/extraction run on-device.
- Reliable automation: idempotent ingestion and repeat-safe writes.
- Explainability: all schedule changes should be revisioned and auditable.
- Multi-account support: multiple Gmail + Outlook accounts in one runtime.

Constraints:
- macOS-focused runtime (EventKit, launch helper architecture).
- Live sync depends on local ONNX model availability.
- LLM output is treated as untrusted until validated.

## 3) System At A Glance

Main runtime entrypoint:
- `Sources/SenseAssistHelper/main.swift`

High-level component map:
- `Sources/Integrations/Gmail` and `Sources/Integrations/Outlook`: provider API clients + incremental fetch cursors.
- `Sources/ParserPipeline`: rule-based parsing and evidence/tag generation.
- `Sources/RulesEngine`: deterministic approval/reject/confirmation gates.
- `Sources/Ingestion`: sync services, triage routing, auto-planning trigger coordination.
- `Sources/LLMRuntime`: ONNX/Ollama runtimes, prompt contracts, JSON materialization/repair.
- `Sources/Storage`: SQLite migrations + repositories for updates/tasks/cursors/revisions/operations/audit.
- `Sources/Integrations/EventKitAdapter`: managed calendar create/update/delete.
- `Sources/Integrations/Slack` + `Sources/Orchestration`: `/plan` command parsing and execution.

## 4) End-to-End Runtime Flows

### 4.1 Live Sync Flow (Email -> Tasks -> Plan -> Calendar)

1. `SenseAssistHelper` loads config, DB, credentials, and ONNX runtime.
2. `MultiAccountSyncCoordinator` iterates enabled accounts.
3. Provider client fetches incremental pages using tuple cursor semantics (`time + messageID`).
4. `ParserPipeline` extracts structured `UpdateCard`s.
5. `RulesEngine` validates parser confidence + mandatory fields.
6. `TaskIntentTriageEngine` classifies updates into actionable/maybe/ignore.
7. Only actionable items go to LLM extraction.
8. Extracted tasks are normalized and upserted to DB.
9. After the account cycle, `AutoPlanningService` (if available) requests LLM schedule, validates it, and diffs managed blocks in EventKit.
10. Plan revisions and operations are persisted.

### 4.2 Background Loop

The helper loop uses `AdaptiveSyncScheduler` states:
- `active`
- `normal`
- `idle`
- `error(retryCount)` with exponential backoff + jitter.

### 4.3 Slack Command Flow

1. Slack Socket Mode receives `/plan`.
2. `PlanCommandParser` parses `today`, `add`, `move`, `undo`, `help`.
3. `PlanCommandService` validates operation via `RulesEngine`.
4. Managed block mutation happens via EventKit adapter.
5. Operation + revision are persisted; undo state is recoverable from storage.

## 5) On-Device LLM Runtime: What Exists Today

Default live runtime:
- `ONNXGenAILLMRuntime` (ORT GenAI runner script path)

Alternative runtime:
- `OllamaLLMRuntime` exists but is not the default live wiring.

### 5.1 Performance and Power Optimizations

Already in architecture before recent updates:
- int4 AWQ model profile (`cpu-int4-awq-block-128-acc-level-4`)
- triage and confidence gating to reduce unnecessary inference calls
- bounded retry policy (`maxAttempts = 2`)
- auto-planning triggered once per full sync cycle

Added in latest runtime update:
- warm ONNX daemon mode: model/tokenizer stay loaded across requests
- one-shot fallback path if daemon transport fails
- per-intent token budgets:
  - extraction
  - due-date repair
  - Slack edit parsing
  - schedule generation
- env overrides for each per-intent budget

KV cache status:
- per-generation autoregressive KV behavior is handled internally by ORT generator.
- cross-request prefix KV cache reuse is not explicitly implemented yet.

## 6) Data Model and Persistence

Database:
- SQLite at `~/.senseassist/senseassist.sqlite` by default.

Core tables:
- `updates`
- `tasks`
- `task_sources`
- `provider_cursors`
- `accounts`
- `blocks`
- `plan_revisions`
- `operations`
- `audit_log`
- `preferences`

Important persistence properties:
- deterministic SHA-256 content hash for updates
- per-account provider cursors
- dedupe key for tasks (`title|category|due-date bucket`)
- source-level confidence attached to tasks
- operation status transitions include undo tracking (`applied` -> `undone`)

## 7) Integrations and Authentication

Gmail:
- REST API pagination + overlap-safe query (`after:cursor-1s`)
- tuple comparison on `(internalDateSeconds, messageID)`

Outlook:
- Graph API paging via `@odata.nextLink`
- tuple comparison on `(receivedDateTime, messageID)`

Slack:
- Socket Mode connect/reconnect with exponential reconnect delay
- command routing to plan service

EventKit:
- writes restricted to managed calendar scope
- managed marker in event notes for safe identification

Credentials:
- environment-first credential loading
- optional keychain fallback (`SENSEASSIST_USE_KEYCHAIN=1`)
- refresh-token support for Gmail/Outlook in helper flow

## 8) Guardrails and Safety Model

Safety stance:
- all external payloads are untrusted until validated.
- LLM outputs are schema-constrained and then decoded/validated in Swift.
- schedule plans are checked for overlaps, time windows, and daily caps before writes.
- non-agent or ambiguous command targets require confirmation paths.

Operational safety:
- per-account sync failures are isolated and do not crash full cycle.
- managed calendar-only mutation policy reduces accidental collateral edits.

## 9) How To Run and Validate Locally

Core commands (from `Makefile`):
- `make test`
- `make helper-health`
- `make llm-install`
- `make llm-smoke`
- `make llm-bench`
- `make sync-all-demo`
- `make sync-all-live`
- `make db-summary`

Minimal productive local path:
1. `make test`
2. `make llm-install`
3. `source ./.env.onnx.local`
4. `make llm-smoke`
5. `make sync-all-demo`

Live path prerequisites:
- enabled accounts in DB
- OAuth credentials/refresh tokens
- local ONNX model path configured

## 10) Configuration You Must Know

Critical runtime env:
- `SENSEASSIST_ONNX_MODEL_PATH`
- `SENSEASSIST_ONNX_RUNNER`
- `SENSEASSIST_ONNX_PYTHON`
- `SENSEASSIST_ONNX_PROVIDER`
- `SENSEASSIST_ONNX_MAX_NEW_TOKENS`
- `SENSEASSIST_ONNX_TEMPERATURE`
- `SENSEASSIST_ONNX_TOP_P`

Per-intent token caps:
- `SENSEASSIST_ONNX_MAX_NEW_TOKENS_EXTRACT`
- `SENSEASSIST_ONNX_MAX_NEW_TOKENS_DUE_REPAIR`
- `SENSEASSIST_ONNX_MAX_NEW_TOKENS_EDIT`
- `SENSEASSIST_ONNX_MAX_NEW_TOKENS_SCHEDULE`

Planning controls:
- `SENSEASSIST_LLM_SCHEDULER_MODE` (`llm_only`)
- `SENSEASSIST_SCHEDULER_MIN_TASK_CONFIDENCE`
- `SENSEASSIST_ENABLE_DAILY_ROUTINE_TASKS`
- `SENSEASSIST_PLANNER_INPUT_PATH`

Credential controls:
- `SENSEASSIST_USE_KEYCHAIN`
- provider client/secrets + refresh token env keys

## 11) Current Known Gaps / Risks

Most important current gaps:
- menu app onboarding remains placeholder-level
- launch-at-login/service lifecycle still incomplete
- SQLite encryption-at-rest not implemented yet
- full E2E failure matrix coverage is still limited

Performance caveat:
- benchmark report in repo is pre-daemon baseline; re-run locally to get post-optimization numbers.

Repo caveat:
- `Docs/` is gitignored; docs in that folder are local artifacts unless moved/whitelisted.

## 12) Testing Strategy Snapshot

Current state:
- 40/40 tests passing (`swift test`)
- coverage includes ingestion, storage, orchestration, planner, auth, parser pipeline

Notable test emphasis:
- multi-account sync behavior
- confidence gating
- scheduler behavior in `llm_only`
- plan command operations and undo behavior
- migration/repository correctness

## 13) Recommended First Week Plan For New Developer

Day 1:
- run `make test`, `make sync-all-demo`, `make db-summary`
- read `README.md`, this report, and `Sources/SenseAssistHelper/main.swift`

Day 2:
- trace ingestion path end-to-end (Gmail + Outlook -> parser -> rules -> triage -> task upsert)
- inspect `TaskIntentTriageEngine`, `RulesEngine`, and ingestion tests

Day 3:
- trace planning/apply path (`AutoPlanningService` + `LLMRuntime` + EventKit adapter)
- inspect planner snapshot generation and schedule materialization checks

Day 4:
- trace Slack `/plan` parsing and orchestration apply/undo persistence
- inspect operation/audit repositories

Day 5:
- pick one contained improvement:
  - benchmark post-daemon runtime and publish updated report
  - strengthen a missing E2E failure scenario
  - improve one planner validation edge case

## 14) High-Value Files To Read In Order

1. `README.md`
2. `Sources/SenseAssistHelper/main.swift`
3. `Sources/Ingestion/MultiAccountSyncCoordinator.swift`
4. `Sources/Ingestion/GmailIngestionService.swift`
5. `Sources/Ingestion/OutlookIngestionService.swift`
6. `Sources/ParserPipeline/ParserPipeline.swift`
7. `Sources/RulesEngine/RulesEngine.swift`
8. `Sources/LLMRuntime/LLMRuntime.swift`
9. `Sources/Ingestion/AutoPlanningService.swift`
10. `Sources/Integrations/EventKitAdapter/EventKitAdapter.swift`
11. `Sources/Integrations/Slack/SlackIntegration.swift`
12. `Sources/Orchestration/PlanCommandService.swift`
13. `Sources/Storage/SQLiteStore.swift`
14. `Sources/Storage/Repositories.swift`

## 15) Quick Glossary

- `UpdateCard`: normalized inbound message event.
- `TaskItem`: normalized actionable unit for planning.
- `SchedulePlan`: LLM-proposed daily schedule contract.
- `plan_revision`: monotonic revision id for schedule operations.
- `managed block`: EventKit event owned by SenseAssist.
- `llm_only`: scheduler mode that requires LLM scheduling path.

---

If you hand this report to a new developer and pair it with a short walkthrough of `SenseAssistHelper.main`, they should be productive quickly.
