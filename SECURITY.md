# Security Policy

## Supported scope

SenseAssist is currently in beta OSS stage. Security hardening is in progress, with local-first execution as a core principle.

## Reporting a vulnerability

Please do not disclose unpatched vulnerabilities publicly.

Preferred process:

1. Use GitHub Security Advisories (private vulnerability reporting) for this repository.
2. Include:
   - affected component(s)
   - impact
   - reproduction steps
   - potential mitigation, if known
3. Allow maintainers time to triage and coordinate a fix before public disclosure.

## Response targets

- Initial triage acknowledgment: within 7 days
- Status update cadence: at least weekly until resolution

## Security boundaries in current architecture

- OAuth credentials are loaded from environment variables and optionally keychain.
- Email and Slack payloads are treated as untrusted input.
- Calendar writes are constrained to managed SenseAssist events.

## Current limitations

- SQLite encryption-at-rest is not yet implemented.
- Full production-grade incident response and signing policy is not yet finalized.
