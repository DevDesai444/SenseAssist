# Governance

## Project model

SenseAssist is maintained as an open-source, local-first automation project. Maintainers are responsible for architecture direction, release quality, and security triage.

## Decision process

- Architectural decisions should be documented in pull requests and linked issues.
- Breaking changes require explicit migration notes in PR descriptions.
- Security-impacting changes should reference `SECURITY.md` process.

## Roles

- Maintainers:
  - review and merge pull requests
  - manage release quality gates
  - moderate project discussions
- Contributors:
  - propose changes through issues and pull requests
  - provide tests and docs for behavior changes

## Release expectations

- Stable behavior changes should include tests.
- Runtime or data-model changes should include clear rollback guidance.
- Documentation must be updated for user-facing command or setup changes.
