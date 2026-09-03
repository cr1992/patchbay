---
name: use-patchbay
description: Connect to, inspect, diagnose, or safely drive a running Dart or Flutter app that explicitly integrates Patchbay. Use for Patchbay setup, sessions, catalog or snapshot inspection, UI and domain commands, logs, captures, and Patchbay-backed verification; do not use as a substitute for adb, xcrun, product runtime code, or authorization for side effects.
---

# Use Patchbay

Patchbay is an opt-in white-box control channel inside a running App. The App must integrate the
matching Patchbay host before this skill can connect to it. The skill is workflow guidance, not a
runtime, plugin, launcher, or permission grant.

## Route the task

- If the consumer has not installed the Skill, CLI, or App dependency, read [INSTALL.md](INSTALL.md).
- If session selection or connection is failing, start with the generated `doctor` command below.
- If the user wants to inspect state, establish identity, read the live catalog, and request only the
  smallest snapshot path that can answer the question.
- If the user wants to invoke a service command, inspect its live descriptor before constructing the
  request. The runtime catalog owns availability, parameters, gates, retry eligibility, and sensitive
  input facts.
- If output is large, prefer a CLI-advertised brief, path selection, output file, or artifact flow.
  Machine consumption should default to `--json --view brief`; a field a brief response leaves out is
  never silent — it is always named in that response's `localView.omitted`, so a missing field is not
  evidence the App omitted it. Expand with `--view full` (overridable per line inside a repl session)
  only when the task requires it, and treat that expansion as a new observation, not a replay of the
  brief one.
- Read the repository guide or a focused package document only when live help and descriptors do not
  answer the current task. Do not preload the complete guide for routine diagnosis.

## Working contract

- Start read-only. A request to inspect or diagnose does not authorize App mutation, device actions,
  installation, builds, permission changes, or external side effects.
- Use Patchbay only with an explicitly enabled debug or profile host. Do not make a release host
  reachable to satisfy this workflow.
- Treat a VM Service URI as authentication material. Do not commit it or copy it into durable logs,
  scripts, fixtures, or reports.
- Treat the live catalog as the capability truth source. Do not infer that a command is available
  merely because this Skill or a README mentions it.
- Preserve generation, revision, gate, sensitive-stdin, timeout, and retry requirements from the live
  descriptor. Do not convert a rejected or unavailable operation into a lower-level bypass.
- CLI exit success proves the documented Patchbay reply, not pixels, hardware behavior, Store state,
  or completion of an accepted asynchronous job. Read the relevant snapshot, job, log, capture, or
  platform fact source before claiming the outcome.
- Patchbay complements platform tools. Keep adb, xcrun, native automation, and physical-device claims
  within their own evidence boundaries.

## Read-only starter commands

The block below is generated from the CLI registry. Do not hand-edit command spellings here.

<!-- PATCHBAY_COMMAND_REFERENCE:START -->
Run the smallest read-only sequence that can answer the task:
- `patchbay doctor` — Check session, connection, catalog and App lifecycle in one pass.
- `patchbay identity` — Read the runtime identity handshake.
- `patchbay catalog` — List the commands and UI targets the App registers.
- `patchbay snapshot [--path <dot.path>]` — Read the transport-level Patchbay snapshot.
- `patchbay describe <service-command>` — Describe one live service command and its retry eligibility.
<!-- PATCHBAY_COMMAND_REFERENCE:END -->

## Canonical UI writes

Use `patchbay ui perform` for UI writes. Keep the `target:`, `semantics:`, or `node:` selector explicit;
`tap` also requires `--via semantics` or `--via pointer`, and Patchbay never falls back to another channel.
The table is generated from the same registry that resolves commands and emits runtime warnings.

<!-- PATCHBAY_UI_MIGRATION:START -->
| Deprecated in 0.6.0 | Canonical replacement | Removal |
|---|---|---|
| `ui text set` | `ui perform enter-text target:<id> <generation> [text]` | 1.0 |
| `ui text enter` | `ui perform enter-text target:<id> <generation> [text]` | 1.0 |
| `ui tap` | `ui perform tap semantics:<identifier> <generation> --via semantics` | 1.0 |
| `ui action` | `ui perform action semantics:<identifier> <generation> <action> [text]` | 1.0 |
| `ui semantics action` | `ui perform action node:<node-id> <generation> <action> [text]` | 1.0 |
| `ui gesture tap` | `ui perform tap semantics:<identifier> <generation> --via pointer [--start <json>]` | 1.0 |
| `ui gesture press-hold` | `ui perform press-hold semantics:<identifier> <generation> --start <json> [--duration-ms <ms>]` | 1.0 |
| `ui gesture drag` | `ui perform drag semantics:<identifier> <generation> --start <json> --gesture-path <json> [--duration-ms <ms>]` | 1.0 |
| `ui gesture fling` | `ui perform fling semantics:<identifier> <generation> --start <json> --velocity <json> [--duration-ms <ms>]` | 1.0 |
| `ui reveal` | `ui perform reveal semantics:<identifier> [--container <identifier>] [--direction <forward\|backward\|both>] [--max-steps <n>] [--timeout-ms <ms>]` | 1.0 |
<!-- PATCHBAY_UI_MIGRATION:END -->

Use only the commands needed for the question. When launcher discovery is unavailable, inspect the
CLI connection options and supply the running App's VM Service URI without persisting it.

## Disclosure order

1. Use this entrypoint to select the workflow and retain safety boundaries.
2. Use the generated starter commands for connection and read-only facts.
3. Use live catalog, descriptor, and help output for command-specific facts.
4. Load focused installation or integration documentation only when that work is actually required.
5. Load the complete guide or full artifacts only for deep reference and evidence review.

If a lower layer answers the question, stop there.
