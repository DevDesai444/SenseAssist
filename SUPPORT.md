# Support

## Getting help

- Usage and setup questions: open a GitHub Discussion or issue.
- Bug reports: open a GitHub issue with repro steps and logs.
- Security concerns: follow `SECURITY.md`.

## What to include in support requests

- Environment details (macOS version, Swift version).
- Exact command run and output.
- Relevant configuration (without secrets).
- Expected behavior vs actual behavior.

## Operational quick checks

1. `swift test`
2. `swift run senseassist-helper --health-check`
3. `source ./.env.onnx.local && make llm-smoke`
4. `make sync-all-live`

## Scope notes

- Outlook live sync requires valid Microsoft OAuth credentials.
- Gmail live sync requires Gmail API enabled and valid OAuth credentials.
- On-device planning requires `SENSEASSIST_ONNX_MODEL_PATH`.
