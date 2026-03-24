# SenseAssist scheduling simulator

This folder contains a small command-line simulator that reads tasks from an `input.*` file, runs the scheduler, and prints a day plan to stdout based on the current date/time.

## Run

From the repo root:

```bash
swift run senseassist-schedule-sim
```

By default it looks for `input.*` in:

1) the current working directory, then  
2) `Sources/LLMRuntime/LLM_Scheduling_algo/`

You can also specify a path explicitly:

```bash
swift run senseassist-schedule-sim --input Sources/LLMRuntime/LLM_Scheduling_algo/input.json
```

## Scheduler modes

```bash
swift run senseassist-schedule-sim --scheduler stub
swift run senseassist-schedule-sim --scheduler planner
```

- `stub` uses `StubLLMRuntime.inferSchedulePlan` (deterministic, no model required).
- `planner` uses `PlannerEngine.plan` (deterministic greedy scheduler).

## Input format

Recommended: JSON (see `input.json`).

You can provide either:

- a JSON object `{ "tasks": [...] }`, or
- a JSON array `[ ...tasks... ]`

Minimal task fields:

- `title` (required)
- `category` (optional; assignment|quiz|email_reply|application|leetcode|project|admin)
- `due_at_local` (optional; ISO-8601)
- `estimated_minutes`, `min_daily_minutes`, `priority`, `stress_weight`, `status` (optional)

Plain-text input is also supported: any non-empty line becomes a task title with defaults.

