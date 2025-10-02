# Contributing to SenseAssist

Thank you for contributing.

## Development setup

1. Install prerequisites:
   - macOS 13+
   - Xcode Command Line Tools
   - Swift 6
2. Clone repository and enter workspace.
3. Run baseline checks:
   - `swift test`
   - `swift run senseassist-helper --health-check`

## Contribution workflow

1. Create a feature branch from `main`.
2. Keep changes scoped to one concern per pull request.
3. Add or update tests for behavior changes.
4. Update docs when commands, environment variables, or architecture change.
5. Open a pull request with:
   - problem statement
   - implementation summary
   - verification evidence (tests/commands run)
   - risks and rollback notes (if runtime behavior changed)

## Code quality expectations

- Prefer deterministic behavior at integration boundaries.
- Keep trust boundaries explicit: untrusted input must pass parser/rules checks.
- Avoid introducing hidden side effects in calendar write paths.
- Preserve idempotency for ingestion and storage upserts.

## Commit guidance

- Use clear, imperative commit messages.
- Split large work into logical commits.
- Avoid mixing refactors and behavior changes without clear rationale.

## Testing guidance

- Unit tests belong in the corresponding module test target under `Tests/`.
- Add integration tests when cross-module behavior changes:
  - ingestion + storage
  - planning + EventKit adapter
  - orchestration + rules validation

## Documentation

If your change affects runtime operations, update:

- `README.md`
- `PROJECT_SPEC_V2.md` when spec-level behavior changes
- `Docs/GITHUB_ISSUES_MVP_BACKLOG.md` when roadmap status changes
