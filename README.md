![SenseAssist banner](Logos/3.png)

# SenseAssist

Local-first, on-device AI assistant that converts inbox updates into auditable calendar execution.

SenseAssist ingests Gmail and Outlook updates, extracts actionable work, plans deep-work blocks with an on-device LLM, and applies managed changes to Apple Calendar with revisioned history.

## Project status (March 3, 2026)

- Stage: Beta OSS
- Platform: macOS 13+
- Language: Swift 6
- Runtime mode: local-first (no cloud dependency required for planning)
- Test status: 39/39 tests passing (`swift test`)

## Why SenseAssist

- Local-first privacy: ingestion, parsing, planning, and calendar mutation run on-device.
- Reliable automation: idempotent sync, deterministic storage state, guarded write paths.
- Explainable operations: revision tracking, operation logs, undo-ready plan edits.
- Multi-account support: Gmail + Outlook account-level cursors and selective enablement.

## Core capabilities

- Email ingestion:
  - Incremental Gmail sync with tuple cursor (`internalDate`, `messageID`).
  - Incremental Outlook Graph sync with tuple cursor (`receivedDateTime`, `messageID`).
  - Per-account cursor persistence and deduplicated update ingestion.
- Task intelligence:
  - Rule-based parsing for trusted sources, digest splitting, tagging, and confidence scoring.
  - LLM extraction from approved updates into normalized `TaskItem` records.
  - Due-date repair pass when extraction misses required due dates.
- Scheduling:
  - LLM-only scheduler for auto-planning (`llm_only` mode).
  - `planner_input.json` snapshot generated before each planning run and consumed by runtime prompts.
  - Student routine task injection (LeetCode, internships, meals, hygiene, mental reset) with opt-out env flag.
  - Policy-aware scheduling prompts:
    - defer short due-soon tasks (example: due in 2 days) toward day-before-due when feasible
    - enforce daily progress on large assignments
  - Feasibility state tracking: `on_track`, `at_risk`, `infeasible`.
- Execution:
  - Managed Apple Calendar writes through EventKit adapter.
  - Slack `/plan` command handling (`today`, `add`, `move`, `undo`, `help`).
  - Revision and operation persistence for audit and rollback behavior.

## Architecture

```mermaid
flowchart TB
    subgraph External
        A["Gmail API"]
        C["Outlook Graph API"]
        M["Slack Socket Mode"]
    end

    subgraph Ingestion
        B["GmailIngestionService"]
        D["OutlookIngestionService"]
        E["ParserPipeline + RulesEngine"]
        F["LLMRuntime<br/>(Task Extraction)"]
    end

    subgraph Planning
        G["Storage<br/>(SQLite tasks/updates)"]
        H["AutoPlanningService"]
        I["planner_input.json"]
        J["LLMRuntime<br/>(Schedule + Repair)"]
        K["SchedulePlan<br/>Validation"]
        N["PlanCommandService"]
    end

    subgraph Execution
        L["EventKitAdapter<br/>(Managed Blocks)"]
    end

    A --> B
    C --> D
    B --> E
    D --> E
    E --> F
    F --> G
    G --> H
    H --> I
    I --> J
    J --> K
    K --> L
    M --> N
    N --> L
    N --> G
```

## Repository layout

- `Sources/CoreContracts`: shared domain models and configuration.
- `Sources/Storage`: SQLite store, migrations, repositories.
- `Sources/Ingestion`: provider ingestion and multi-account coordination.
- `Sources/ParserPipeline`: deterministic parsing + confidence signals.
- `Sources/LLMRuntime`: ONNX and Ollama runtime clients, extraction/scheduling prompts, response validation.
- `Sources/Planner`: deterministic planner module (kept for tests/tools, not used by auto-planning live path).
- `Sources/Integrations`: Gmail, Outlook, Slack, EventKit adapters.
- `Sources/Orchestration`: `/plan` command parser/service and undo flow.
- `Sources/SenseAssistHelper`: runtime entrypoint and background loop.
- `Tests`: unit/integration tests across modules.
- `Scripts`: model install and smoke-test utilities.

## Quick start

### Prerequisites

- macOS 13+
- Xcode Command Line Tools
- Swift 6 toolchain
- Python 3 (for ONNX runner script)

### 1) Validate build and tests

```bash
swift test
swift run senseassist-helper --health-check
```

### 2) Install and verify on-device model (Phi-3.5 ONNX)

```bash
make llm-install
source ./.env.onnx.local
make llm-smoke
```

### 3) Configure OAuth credentials (env-first)

Create `.env.oauth.local`:

```bash
export SENSEASSIST_GMAIL_CLIENT_ID="<client-id>"
export SENSEASSIST_GMAIL_CLIENT_SECRET="<client-secret>"

export SENSEASSIST_REFRESH_TOKEN_GMAIL_GMAIL_YOUR1_GMAIL_COM="<refresh-token>"
export SENSEASSIST_REFRESH_TOKEN_GMAIL_GMAIL_YOUR2_GMAIL_COM="<refresh-token>"
export SENSEASSIST_REFRESH_TOKEN_GMAIL_GMAIL_YOUR3_GMAIL_COM="<refresh-token>"

# Optional Outlook
export SENSEASSIST_OUTLOOK_CLIENT_ID="<client-id>"
export SENSEASSIST_OUTLOOK_CLIENT_SECRET="<client-secret>"
export SENSEASSIST_REFRESH_TOKEN_OUTLOOK_OUTLOOK_YOU_DOMAIN_COM="<refresh-token>"
```

Load env files for the current shell:

```bash
source /absolute/path/to/SenseAssist/.env.oauth.local
source /absolute/path/to/SenseAssist/.env.onnx.local
```

### 4) Run live sync once

```bash
make sync-all-live
make db-summary
```

## Runtime modes

- Live mode:
  - Requires enabled accounts in DB + OAuth env.
  - Requires `SENSEASSIST_ONNX_MODEL_PATH`.
  - Command: `make sync-all-live`.
- Demo mode:
  - Uses stub providers and synthetic accounts.
  - Requires explicit enable flag.
  - Command: `SENSEASSIST_ENABLE_DEMO_COMMANDS=1 make sync-all-demo`.

## LLM scheduling configuration

- Scheduler mode:
  - `SENSEASSIST_LLM_SCHEDULER_MODE`
  - Current supported value: `llm_only` (default).
- Planner input snapshot:
  - `SENSEASSIST_PLANNER_INPUT_PATH` (optional absolute/tilde path).
  - Default: `<db_directory>/planner_input.json`.
  - Snapshot is written before every auto-planning run and then consumed by scheduling prompts.
- Daily routine tasks:
  - `SENSEASSIST_ENABLE_DAILY_ROUTINE_TASKS` (default enabled).
  - Set `0`, `false`, or `no` to disable injected routine tasks.
- ONNX runtime:
  - `SENSEASSIST_ONNX_MODEL_PATH` (required for live sync).
  - `SENSEASSIST_ONNX_RUNNER` (default: `Scripts/onnx_genai_runner.py`).
  - `SENSEASSIST_ONNX_PYTHON` (default: `/usr/bin/python3`).
  - `SENSEASSIST_ONNX_MAX_NEW_TOKENS`, `SENSEASSIST_ONNX_TEMPERATURE`, `SENSEASSIST_ONNX_TOP_P`.
  - `SENSEASSIST_ONNX_PROVIDER` (optional provider hint for runner).
- OAuth:
  - `SENSEASSIST_GMAIL_CLIENT_ID`, `SENSEASSIST_GMAIL_CLIENT_SECRET`.
  - `SENSEASSIST_OUTLOOK_CLIENT_ID`, `SENSEASSIST_OUTLOOK_CLIENT_SECRET`, `SENSEASSIST_OUTLOOK_TENANT`.
  - Refresh token key format: `SENSEASSIST_REFRESH_TOKEN_<PROVIDER>_<NORMALIZED_ACCOUNT_KEY>`.
- Credential source:
  - Default: environment-only.
  - Optional chained lookup (env then keychain): `SENSEASSIST_USE_KEYCHAIN=1`.

## `planner_input.json` example

```json
{
  "meta": {
    "generated_at_utc": "2026-03-03T14:02:11Z",
    "planning_date_local": "2026-03-03",
    "time_zone": "America/New_York",
    "plan_revision": 42
  },
  "constraints": {
    "day_start_local": "2026-03-03T09:00:00-05:00",
    "day_end_local": "2026-03-03T21:00:00-05:00",
    "max_deep_work_minutes_per_day": 240,
    "break_every_minutes": 90,
    "break_duration_minutes": 10,
    "free_space_buffer_minutes": 45,
    "sleep_window": {
      "start": "00:30",
      "end": "08:00"
    }
  },
  "busy_blocks": [
    {
      "title": "Lecture: CSE 331",
      "start_local": "2026-03-03T10:00:00-05:00",
      "end_local": "2026-03-03T11:20:00-05:00",
      "lock_level": "locked",
      "managed_by_agent": false
    }
  ],
  "tasks": [
    {
      "task_id": "c4f111f4-2ecf-4628-a23e-a639547f2f89",
      "title": "Short Assignment",
      "category": "assignment",
      "due_at_local": "2026-03-05T17:00:00-05:00",
      "estimated_minutes": 60,
      "min_daily_minutes": 30,
      "priority": 4,
      "stress_weight": 0.2,
      "confidence": 0.92,
      "is_large_assignment": false,
      "should_defer_until_day_before_due": true,
      "sources": [
        {
          "provider": "gmail",
          "account_id": "gmail:student@buffalo.edu",
          "message_id": "18a1d8f7b90",
          "confidence": 0.92
        }
      ]
    },
    {
      "task_id": "590cf2b6-ad2d-4f6c-a5a0-0deec2188bb3",
      "title": "Large Assignment",
      "category": "assignment",
      "due_at_local": "2026-03-15T23:00:00-04:00",
      "estimated_minutes": 480,
      "min_daily_minutes": 120,
      "priority": 4,
      "stress_weight": 0.4,
      "confidence": 0.89,
      "is_large_assignment": true,
      "should_defer_until_day_before_due": false,
      "sources": [
        {
          "provider": "outlook",
          "account_id": "outlook:student@university.edu",
          "message_id": "AAMkADk3YQ",
          "confidence": 0.89
        }
      ]
    }
  ]
}
```

## Reliability model

SenseAssist is built for controlled automation with explicit validation:

- Untrusted input handling:
  - Email and Slack payloads are treated as untrusted until parser confidence and rule gates pass.
- Strict LLM scheduling path:
  - Auto-planning requires LLM scheduler availability (`llm_only`).
  - No deterministic scheduler fallback in the live auto-planning path.
- Output hardening:
  - LLM extraction and schedule generation use multi-attempt repair prompts on invalid output.
  - Schedule output is validated against time-window, overlap, and constraint rules before calendar writes.
- Auditable mutations:
  - Managed calendar-only writes.
  - Revision and operation logs for traceability and undo behavior.

## Current known gaps

- `SenseAssistMenuApp` remains placeholder-level and not production onboarding UX.
- Full launch-at-login service integration is not complete.
- Live helper currently wires ONNX runtime path by default (Ollama runtime exists but is not the default live wiring).
- SQLite encryption-at-rest is not yet implemented.
- End-to-end failure-matrix tests (provider outages, token churn) are still limited.

## Commands

```bash
make help
make test
make helper-health
make llm-install
make llm-smoke
make sync-all-demo
make sync-all-live
make db-summary
```

## Project standards

- Contribution guide: `CONTRIBUTING.md`
- Security policy: `SECURITY.md`
- Code of conduct: `CODE_OF_CONDUCT.md`
- Support guide: `SUPPORT.md`
- Governance model: `GOVERNANCE.md`

## Contributing

- Open issues and roadmap: GitHub Issues.
- Primary technical scope reference: `PROJECT_SPEC_V2.md`.
- Submit PRs with:
  - clear problem statement
  - test coverage updates when behavior changes
  - migration notes for schema/runtime changes

## License

MIT License. See `LICENSE`.
