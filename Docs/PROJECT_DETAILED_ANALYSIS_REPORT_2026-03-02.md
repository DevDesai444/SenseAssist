# SenseAssist Detailed Analysis Report

Date: March 2, 2026
Repository: `SenseAssist`
Prepared from: codebase inspection + thread analysis + chart/screenshot analysis

## 1. Scope and Evidence Base

This report combines all available intelligence from:

- `codex://threads/019ca82a-bdd3-77a1-a933-4e3aa561359b`
- `codex://threads/019ca83d-8b93-78c1-af7d-b82d8cc551fa`
- `codex://threads/019cac49-e953-7c93-bd01-87d6b461a1c3`

and validates against current repository code in:

- `/Users/DEVDESAI1/Desktop/University_at_Buffalo/Projects/SenseAssist/Sources/*`
- `/Users/DEVDESAI1/Desktop/University_at_Buffalo/Projects/SenseAssist/PROJECT_SPEC_V2.md`
- `/Users/DEVDESAI1/Desktop/University_at_Buffalo/Projects/SenseAssist/README.md`
- `/Users/DEVDESAI1/Desktop/University_at_Buffalo/Projects/SenseAssist/Docs/GITHUB_ISSUES_MVP_BACKLOG.md`

Thread `019cac49...` included 18 screenshot/image artifacts (Google Cloud OAuth setup workflow and runtime outputs). Those visual artifacts were analyzed and mapped into this report.

## 2. Executive Summary

SenseAssist is a local-first macOS planning system that ingests Gmail/Outlook updates, extracts actionable tasks, and applies a deterministic planning output into Apple Calendar via EventKit, with Slack as an interactive control channel.

Current system state is materially stronger than earlier snapshots in the conversations. Core ingestion, planner wiring, adaptive scheduling, partial failure handling, Slack routing, operation persistence, and deterministic hashing are implemented. The project is in a hardening and productization phase, not a greenfield architecture phase.

Top remaining gaps are mostly product-completion and reliability-polish items:

- Launch-at-login runtime lifecycle (`SMAppService`) not yet implemented.
- Menu app is CLI-like onboarding output, not a complete UX flow.
- Planner does not fully enforce explicit `sleepStart/sleepEnd` constraints from config.
- Slack command surface does not yet expose full spec intent set.
- LLM extraction still has provenance fallback (`updates.first`) if `source_message_id` missing.
- At-rest database encryption strategy (spec item) is still pending.
- E2E failure-mode coverage remains narrower than spec hardening target.

## 3. Problem Definition and Product Goal

### 3.1 Problem being solved

Students receive fragmented academic obligations across email systems (Gmail, Outlook, LMS notifications, digests). Manual triage into realistic plans is high-friction and inconsistent.

### 3.2 SenseAssist value proposition

SenseAssist turns noisy message streams into structured, constrained, auditable scheduling actions with user control:

- Understand incoming academic updates.
- Convert into task semantics.
- Plan within realistic constraints.
- Apply changes only in managed calendar scope.
- Keep full revision + operation trail with undo.

### 3.3 Product philosophy from chats and code

- Local-first where practical.
- LLM as semantic helper, not side-effect authority.
- Deterministic validation before mutation.
- Fail-safe and auditable by design.

## 4. Intended Architecture vs Implemented Architecture

## 4.1 Intended architecture (from spec)

Spec (`PROJECT_SPEC_V2.md`) defines:

- Interactive flow: Slack -> command parsing -> rules -> planner/event apply.
- Background flow: Gmail/Outlook -> parser + extraction -> planner -> EventKit.
- Guardrails: revision checks, ambiguity handling, confidence gates.
- Reliability: incremental sync, idempotency, recovery, backoff.
- Security/trust: least privilege, managed scope mutations, auditability.

## 4.2 Implemented architecture (current code)

### Process/runtime entry points

- Helper runtime: `/Users/DEVDESAI1/Desktop/University_at_Buffalo/Projects/SenseAssist/Sources/SenseAssistHelper/main.swift`
- Menu runtime: `/Users/DEVDESAI1/Desktop/University_at_Buffalo/Projects/SenseAssist/Sources/SenseAssistMenuApp/main.swift`

### Core modules present

- Auth: env + keychain credential stores.
- Storage: SQLite repositories for updates/tasks/accounts/cursors/revisions/operations/audit.
- Parser pipeline: trusted sender, template typing, digest splitting, confidence tagging.
- Rules engine: edit validation and extraction confidence gating.
- Planner: priority/stress/availability-aware block generation with feasibility state.
- Ingestion: Gmail/Outlook services, multi-account coordinator, adaptive scheduler, auto-planning apply.
- Integrations: Gmail API, Outlook Graph, EventKit adapter, Slack Socket Mode.
- LLM runtime: ONNX Runtime GenAI and Ollama adapters; helper live path requires ONNX model path.

### Trust boundaries in implementation

- Untrusted inputs: email text and Slack text.
- Semi-structured interpretation: parser and LLM extraction.
- Deterministic control: rules, revision checks, planner, operation persistence.
- Side effects: EventKit adapter constrained to managed calendar scope.

## 4.3 Data and state model

Key persisted entities (implemented):

- `accounts`: provider/email/account enable state.
- `provider_cursors`: per-provider + per-account sync cursors.
- `updates`: ingested normalized messages with deterministic content hash.
- `tasks`: deduplicated actionable tasks.
- `task_sources`: source provenance links.
- `plan_revisions`: revision timeline.
- `operations`: applied/undone operation records.
- `audit_log`: structured runtime events.

## 5. Innovation and Differentiators

## 5.1 Innovation in system design

1. Local-first hybrid planning stack
- LLM handles semantic extraction.
- Deterministic orchestration controls mutations.

2. Managed side-effect domain
- Calendar writes constrained to a managed calendar path.

3. Multi-provider incremental ingestion with stable tuple cursors
- Gmail and Outlook both use `time + messageID` cursor tie-breaking.
- Prevents silent misses under same-timestamp bursts.

4. Partial-failure account synchronization
- One failed account does not block all accounts.

5. Regenerate-and-diff apply
- Auto-planning compares existing vs planned blocks and applies only delta operations.

6. Environment-first auth runtime with optional keychain fallback
- Reduced interactive prompt loops.
- Better predictable behavior in unattended loops.

## 5.2 Practical innovation in developer experience

- ONNX install/smoke workflow integrated in project scripts and docs.
- Explicit runtime failures for missing model path and missing credentials.
- Deep README status matrix mapping spec, code, and backlog drift.

## 6. Thread-by-Thread Analysis

## 6.1 Thread `019ca82a...` (plan and implementation audit)

Primary purpose in conversation history:

- Establish current project plan from spec.
- Produce done vs pending analysis.
- Build issue/backlog strategy.
- Explore on-device LLM strategy and model/runtime decisions.

Important historical note:

- Early findings in this thread flagged several high-priority gaps that were subsequently addressed in later commits and threads.
- Therefore, this thread is best interpreted as baseline gap discovery, not final state.

Key outputs from this thread:

- Structured MVP completion tracker concept.
- Risk-first audit mindset.
- Initial hardening queue.

## 6.2 Thread `019ca83d...` (README and project-plan consolidation)

Primary purpose:

- Update `README.md` in-depth with architecture, scorecard, roadmap, and current-state docs.

Result:

- README now includes mission, architecture, primary flows, milestone scorecard, backlog reconciliation, local runbook, and known gaps.
- This thread converted scattered implementation details into a project-level narrative artifact.

## 6.3 Thread `019cac49...` (execution, OAuth setup, runtime debugging)

Primary purpose:

- Execute live system setup.
- Configure on-device model path usage and OAuth.
- Diagnose runtime errors (especially keychain prompt loops and credential failures).

Major outcomes:

- Env-first OAuth loading + keychain interaction reduction.
- Multi-account sync resilience improvements.
- Auth fallback tests and docs updates.
- Practical setup path for 3 Gmail + 1 Outlook account configuration.

## 7. Chart and Screenshot Analysis (18 images from `019cac49...`)

No Mermaid/diagram blocks were found in threads `019ca82a...` and `019ca83d...`.
Image-based chart content appears in `019cac49...` and reflects OAuth setup workflow progression.

## 7.1 What the screenshots show

1. Google Cloud project dashboard and APIs page (initial context confusion around API scope selection).
2. OAuth branding/contact/consent setup steps.
3. Audience page in testing mode with test users configured.
4. Data access page initially empty and then updated with Gmail scope.
5. Scope picker confusion due irrelevant BigQuery/storage scopes shown alongside required Gmail scope.
6. OAuth client creation (`Web application`) with redirect URI for OAuth playground flow.
7. OAuth Playground setup using project credentials.
8. Authorization code exchange and refresh token generation succeeded.
9. Later screenshots showing project selection issues (`select a project`) causing API visibility confusion.

## 7.2 Key operational insight from chart flow

The dominant challenge was not coding logic but cloud-console correctness and credential lifecycle discipline:

- Selecting correct project context.
- Configuring right scope (`gmail.readonly`) and test users.
- Correctly using redirect URI (not origin path misuse).
- Persisting long-lived refresh-token based auth rather than short-lived access-token-only runs.

## 8. Current Code-State Validation (March 2, 2026)

Validation commands executed:

- `swift test` (outside sandbox due SwiftPM restrictions): passed 34 tests.
- `swift run senseassist-helper --health-check`: passed.
- `swift run senseassist-helper --plan 'today'`: executed and returned expected calendar permission remediation when permission unavailable.
- `SENSEASSIST_ENABLE_DEMO_COMMANDS=1 swift run senseassist-helper --sync-all-demo`: executed and produced account-level summary.
- `swift run senseassist-helper --sync-live-once`: failed as expected without ONNX model env path set.
- `swift run senseassist-menu --list-accounts`: listed linked accounts (includes demo and real accounts currently enabled).

## 9. Milestone and Backlog Reconciliation

## 9.1 Spec milestones (M0-M5)

Current status interpretation:

- M0 Foundation: implemented.
- M1 Slack + Calendar core: mostly implemented; command surface narrower than full spec.
- M2 Gmail ingestion pipeline: implemented with cursor hardening.
- M3 UB/Piazza intelligence: partially implemented; deterministic pipeline present, richer extraction fidelity still evolving.
- M4 Outlook + adaptive scheduler: implemented core behavior.
- M5 Hardening: partially implemented, still active.

## 9.2 Backlog drift

`Docs/GITHUB_ISSUES_MVP_BACKLOG.md` still contains several items marked as not-final that are now implemented in code (pagination, Slack routing, scheduler wiring, deterministic hash, ingestion->planner flow, revision persistence). It should be refreshed to avoid planning against stale assumptions.

## 10. What is Strongly Implemented Today

1. Gmail and Outlook incremental sync with stable cursor semantics and pagination.
2. Multi-account coordination with partial failure continuation.
3. Parser + confidence gating pipeline.
4. LLM extraction runtime integration and ONNX live-path requirement.
5. Auto-planning regeneration and EventKit delta apply.
6. Slack socket command routing for core `/plan` actions.
7. Revision and operation persistence with undo reconstruction.
8. Deterministic SHA-256 update content hashing.
9. Adaptive scheduler used in background loop.
10. Auth refresh flow for Gmail and Outlook using refresh tokens and app credentials.

## 11. Gaps, Constraints, and Risks Still Open

## 11.1 Product-completion gaps

1. Launch-at-login (`SMAppService`) not implemented.
2. Menu app is still a CLI-style status/onboarding helper, not a full menu UX flow.
3. Full Slack command contract from spec not yet exposed in parser/runtime.

## 11.2 Reliability/behavior gaps

1. Revision increments occur before mutation completion in some plan command paths, risking revision drift on failure.
2. Some persistence calls intentionally use `try?` and can silently drop operation/revision metadata on storage errors.
3. Planner uses workday and cutoff constraints but does not fully model explicit `sleepStart/sleepEnd` windows from config.
4. Task dedupe key (`category + lower(title) + due`) may over-collapse distinct tasks with similar titles.

## 11.3 LLM extraction fidelity gaps

1. `source_message_id` fallback to `updates.first` if payload omits source mapping.
2. Due date parsing is implemented, but real-world extraction fidelity still depends on model output quality.

## 11.4 Security posture gaps

1. At-rest encryption for SQLite is not yet integrated.
2. Credential strategy has improved, but long-term secret governance and rotation policies should be formalized.

## 11.5 Test coverage gaps

1. Strong module and integration tests exist.
2. Full end-to-end failure matrix from spec is not fully covered (permission revoke/recover, full reconnect matrix, auth expiry permutations, etc.).

## 12. Challenges Faced and Decisions Made

### Challenge A: False confidence from narrow success checks

Decision:

- Move from test-only confidence to line-level code audits + spec reconciliation + runtime probes.

### Challenge B: Incremental sync correctness under real message volume

Decision:

- Introduce pagination and tuple cursor tie-break semantics for both providers.

### Challenge C: OAuth and credential management friction

Decision:

- Implement refresh-token support and env-first credential loading by default.
- Make keychain fallback optional and non-interactive in runtime loops.

### Challenge D: Multi-account reliability

Decision:

- Shift coordinator behavior to partial-failure continuation and explicit per-account failure reporting.

### Challenge E: LLM reliability for strict structured extraction

Decision:

- Keep deterministic gates and execution boundaries; treat model as semantic assistant, not authority.
- Commit to ONNX local runtime for live path.

### Challenge F: Planning transparency and reversibility

Decision:

- Persist revisions and operations; add undo hydration from stored operation log.

### Challenge G: Drift between plan docs and implementation

Decision:

- Expand README into implementation-aware scorecard; identify stale backlog items.

## 13. Important Architectural Decisions (Condensed)

1. Local-first runtime with on-device model dependency for live sync.
2. Deterministic mutation guardrails over model output.
3. Managed calendar-only write scope.
4. Account-level fault isolation in sync coordinator.
5. Adaptive scheduler state machine over fixed polling.
6. Revision + operation persistence for audit/undo semantics.
7. Environment-first credential chain to reduce keychain prompt loops.

## 14. Current Runtime Inventory Snapshot

From `senseassist-menu --list-accounts`:

- 3 real Gmail accounts enabled.
- 1 real Outlook account enabled.
- 4 demo accounts still present and enabled in DB.

This is not a code defect by itself, but it is operationally noisy. Account state hygiene and demo/real environment separation should be enforced via startup profile policy.

## 15. Recommended Next Execution Plan

## 15.1 P0 (highest leverage)

1. Implement launch-at-login and helper lifecycle guardrails.
2. Make revision updates atomic with mutation outcomes in plan command paths.
3. Remove silent `try?` in critical persistence flows and surface explicit error handling.
4. Refresh MVP backlog doc to match actual code truth.

## 15.2 P1

1. Expand Slack command surface toward spec completeness.
2. Strengthen LLM extraction provenance and due-date reliability.
3. Enforce explicit sleep window constraints in planner.
4. Formalize demo-account isolation policy.

## 15.3 P2

1. Design and implement at-rest encryption strategy.
2. Build full E2E failure-mode suite from spec section 18.3.
3. Extend observability for account-level sync timelines and auth-refresh outcomes.

## 16. Strategic Project Positioning

The project has moved beyond prototype-level architecture and now demonstrates substantial production-shape system design:

- Multi-provider ingestion correctness concerns are actively addressed.
- Safety and trust boundaries are explicit in code.
- Auth, recovery, and partial-failure behavior are engineering priorities.
- The remaining work is mostly hardening and UX/lifecycle completion.

This is a strong signal of backend/system reliability engineering capability, especially in AI-integrated product workflows.

## 17. Final Conclusion

SenseAssist is not an incomplete concept; it is an actively maturing local-first planning platform with meaningful core architecture already implemented.

The conversation history shows a clear evolution:

- initial gap discovery,
- architecture correction,
- runtime hardening,
- OAuth operationalization,
- and stronger system reliability discipline.

The project's next phase should focus on productization and trust hardening, not architectural reinvention.

