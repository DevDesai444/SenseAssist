# SenseAssist GitHub Issue Backlog (MVP Finalization)

This file contains issue-ready drafts for GitHub. It is organized as one parent tracker plus child issues.

Repository: `https://github.com/DevDesai444/SenseAssist`

## Parent Tracker

### Title
`MVP Completion Tracker: remove temporary scaffolding and close production blockers`

### Labels
`tracking`, `mvp`, `priority:p0`

### Body
```
## Goal
Track MVP completion work required to remove non-final scaffolding and production blockers.

## Dependency Order
1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9 -> 10 -> 11 -> 12 -> 13

## Child Issues
1. Fix Gmail incremental sync to prevent missed messages (pagination + stable cursor tie-breaker)
2. Fix Outlook incremental sync to prevent missed messages (pagination + stable cursor tie-breaker)
3. Wire ingestion to planner and EventKit apply path (email -> tasks -> plan -> calendar)
4. Complete Slack Socket Mode command routing and response loop
5. Persist plan revision and undo history across helper restarts
6. Use adaptive scheduler in runtime loop with retry/backoff states
7. Remove hardcoded default accounts and dev identity values from production path
8. Move demo-only CLI sync flows behind dev mode and exclude from production runtime path
9. Replace placeholder menu app with onboarding/permissions/account setup MVP UI
10. Improve LLM extraction fidelity (task provenance per message + due date propagation)
11. Make update content hash deterministic and stable across runs
12. Remove hardcoded EventKit calendar name in fetch/find/delete paths
13. Add missing E2E/regression coverage for Slack/EventKit/live provider failure modes

## MVP DoD Checklist (PROJECT_SPEC_V2.md section 21)
- [ ] Helper starts automatically at login and stays healthy.
- [ ] Slack `/plan today|add|move` works end-to-end.
- [ ] Gmail ingestion is incremental and idempotent.
- [ ] UB Learns/Piazza notification emails produce tasks with confidence gating.
- [ ] Planner enforces sleep, stress, break, and cutoff constraints.
- [ ] Calendar changes stay inside dedicated agent-managed calendar by default.
- [ ] Every change is auditable and undoable.
```

## Child Issue Drafts

### 1) Fix Gmail incremental sync to prevent missed messages (pagination + stable cursor tie-breaker)
- Labels: `bug`, `area:ingestion`, `provider:gmail`, `priority:p0`
- Evidence: `Sources/Integrations/Gmail/GmailIntegration.swift:64`
- Not-final behavior: single-page fetch, timestamp-only cursor, no stable tie-breaker.

### 2) Fix Outlook incremental sync to prevent missed messages (pagination + stable cursor tie-breaker)
- Labels: `bug`, `area:ingestion`, `provider:outlook`, `priority:p0`
- Evidence: `Sources/Integrations/Outlook/OutlookIntegration.swift:64`
- Not-final behavior: single-page fetch, timestamp-only cursor, no `nextLink` traversal.

### 3) Wire ingestion to planner and EventKit apply path (email -> tasks -> plan -> calendar)
- Labels: `feature`, `area:planner`, `area:ingestion`, `priority:p0`
- Evidence:
  - `Sources/Ingestion/GmailIngestionService.swift:101`
  - `Sources/Ingestion/OutlookIngestionService.swift:101`
- Not-final behavior: tasks are stored, but plans/blocks are not generated/applied.

### 4) Complete Slack Socket Mode command routing and response loop
- Labels: `feature`, `area:slack`, `priority:p0`
- Evidence:
  - `Sources/Integrations/Slack/SlackIntegration.swift:116`
  - `Sources/SenseAssistHelper/main.swift:59`
- Not-final behavior: socket acks only; commands are not routed from Slack events to orchestration.

### 5) Persist plan revision and undo history across helper restarts
- Labels: `bug`, `area:orchestration`, `priority:p1`
- Evidence: `Sources/Orchestration/PlanCommandService.swift:28`
- Not-final behavior: revision and undo stack are in-memory only.

### 6) Use adaptive scheduler in runtime loop with retry/backoff states
- Labels: `feature`, `area:ingestion`, `priority:p1`
- Evidence:
  - `Sources/Ingestion/AdaptiveSyncScheduler.swift:21`
  - `Sources/SenseAssistHelper/main.swift:103`
- Not-final behavior: scheduler exists but helper loop uses fixed sleep.

### 7) Remove hardcoded default accounts and dev identity values from production path
- Labels: `cleanup`, `security`, `priority:p1`
- Evidence: `Sources/SenseAssistHelper/main.swift:18`
- Not-final behavior: personal account IDs/emails are compiled into runtime defaults.

### 8) Move demo-only CLI sync flows behind dev mode and exclude from production runtime path
- Labels: `cleanup`, `area:runtime`, `priority:p1`
- Evidence:
  - `Sources/SenseAssistHelper/main.swift:73`
  - `Sources/SenseAssistHelper/main.swift:89`
- Not-final behavior: demo workflows are mixed into main runtime binary behavior.

### 9) Replace placeholder menu app with onboarding/permissions/account setup MVP UI
- Labels: `feature`, `area:menu-app`, `priority:p1`
- Evidence: `Sources/SenseAssistMenuApp/main.swift:10`
- Not-final behavior: placeholder print output only.

### 10) Improve LLM extraction fidelity (task provenance per message + due date propagation)
- Labels: `bug`, `area:llm`, `area:planner`, `priority:p1`
- Evidence:
  - `Sources/LLMRuntime/LLMRuntime.swift:111`
  - `Sources/LLMRuntime/LLMRuntime.swift:119`
- Not-final behavior: tasks map to first message source and always have `dueAtLocal = nil`.

### 11) Make update content hash deterministic and stable across runs
- Labels: `bug`, `area:storage`, `priority:p2`
- Evidence: `Sources/Storage/Repositories.swift:128`
- Not-final behavior: uses randomized Swift `hashValue`.

### 12) Remove hardcoded EventKit calendar name in fetch/find/delete paths
- Labels: `bug`, `area:eventkit`, `priority:p2`
- Evidence:
  - `Sources/Integrations/EventKitAdapter/EventKitAdapter.swift:153`
  - `Sources/Integrations/EventKitAdapter/EventKitAdapter.swift:202`
  - `Sources/Integrations/EventKitAdapter/EventKitAdapter.swift:233`

### 13) Add missing E2E/regression coverage for Slack/EventKit/live provider failure modes
- Labels: `test`, `quality`, `priority:p1`
- Evidence: gaps vs `PROJECT_SPEC_V2.md:866`.
