# patchbay

English | [简体中文](README.zh-CN.md)

`patchbay` is Patchbay's pure Dart protocol and host package. It lets a local client connect to a
running Dart / Flutter app, read the runtime identity, catalog, and snapshot, and invoke the debug
commands that app has explicitly registered.

This package knows nothing about pages, device SDKs, routing, or business domains. The app using
Patchbay (the "consumer" below) is responsible for domain type conversion, gate decisions,
concurrency ownership, redaction, and fact adjudication in its own adapter.

For the full getting-started flow, see the [repository README](../../README.md#quick-start). For
Flutter UI integration see [`patchbay_flutter`](../patchbay_flutter/README.md); for CLI usage see
[`patchbay_cli`](../patchbay_cli/README.md).

## Package Boundaries

| Package | Responsibility | Dependency boundary |
|---|---|---|
| `patchbay` | Protocol, service extension host, gates, command declarations, invocation envelopes, jobs, logs, and blobs | Pure Dart |
| `patchbay_flutter` | Optional Flutter UI, Semantics, navigation, wait, and capture bridge | Flutter + `patchbay` |
| `patchbay_cli` | VM Service / direct client, session discovery, command line, and stable output | Pure Dart |
| `patchbay_transport` | Explicitly enabled direct HTTP/JSON host and client | Pure Dart, no VM Service dependency |

Domain DTOs, branded command aliases, device SDKs, route mappings, and log sources all stay in the
consumer's own project. The general-purpose packages neither depend on those types nor infer
business conclusions from free text, widget state, or command names.

## Core Capabilities

- `PatchbayServiceHost` — registers the four stable entry points: identity, catalog, snapshot, and
  invoke;
- `PatchbayCommandDescriptor` — declares a command's parameters, mode, gates, side effects, and
  permitted fact sources;
- `PatchbayGateEvaluator` — runs the base gate and the declared command gates in a fixed order;
- `PatchbayInvocation` — separates "accepted / rejected" from the domain execution result;
- `PatchbayJobRegistry` — tracks long-running work, monotonic event sequences, cancellation, and
  typed terminal states;
- `PatchbayArtifactService` — serves redacted logs and bounded blob downloads;
- Wire DTOs and codegen — unified fields, enums, validation, and bidirectional JSON codecs.

Flutter UI, Semantics, navigation, and capture are not implemented in this package; they are
composed into the same host catalog by `patchbay_flutter`. Direct HTTP is carried by
`patchbay_transport`, which reuses the same upper-layer handlers.

## Architecture

```text
CLI / automation
       │
       │ VM Service or direct HTTP
       ▼
PatchbayServiceHost
       │
       ├── identity / catalog / snapshot
       ├── PatchbayGateEvaluator
       ├── PatchbayInvocationSource
       └── PatchbayJobRegistry
                    │
                    ▼
             Consumer adapter
                    │
                    ▼
    Existing runtime / controllers / ports
```

The adapter reuses the app's existing controllers and state machines. Patchbay owns the protocol
and the boundaries; it does not reimplement business logic for the CLI's benefit.

## Service Extension

`PatchbayServiceHost` registers four stable RPCs:

| RPC | Meaning |
|---|---|
| `ext.patchbay.identity` | App, isolate, schema, and short-lived instance ID |
| `ext.patchbay.catalog` | The commands and dynamic UI targets actually registered right now |
| `ext.patchbay.snapshot` | The read-only runtime snapshot supplied by the consumer |
| `ext.patchbay.invoke` | Invoke a command present in the catalog |

Every payload carries a `schemaVersion`. `appInstanceId` is stable within one isolate and must
change after a hot restart. On connecting, a client re-validates the schema, isolate, and app
instance — it cannot judge a session still valid from a PID or a stale URI alone.

`schemaVersion` is owned by the host and cannot be overridden by consumer callbacks. Command names
in the catalog must be non-empty and globally unique; an invocation's return value must be a valid
wire envelope echoing back the same `requestId`. When these provider contracts are violated, the
host returns `providerProtocolViolation` rather than passing a result it cannot correlate or parse
on to the client.

Command catalog rows must be objects with a valid dotted `name`; string shorthand is not accepted.
The command name syntax is `^[a-z][A-Za-z0-9]*(?:\.[a-z][A-Za-z0-9]*)+$`: each segment starts with
a lowercase letter and contains only letters and digits — **hyphens are not allowed**
(`auth.switch-tenant` is invalid; write `auth.tenant.switch`). `requestId` must be non-empty; an
accepted envelope must not carry a rejection, and a rejected envelope must carry a rejection and
must not carry a payload or a jobId.

When the catalog violates these rules, the **entire catalog call** returns a rejection envelope
rather than throwing — an exception cannot become a reply over either VM Service or direct HTTP,
so the caller would only ever see a hang:

```json
{
  "schemaVersion": 1,
  "admission": "rejected",
  "rejection": {
    "code": "providerProtocolViolation",
    "details": {
      "reason": "invalidCatalogCommands",
      "commandNamePattern": "^[a-z][A-Za-z0-9]*(?:\\.[a-z][A-Za-z0-9]*)+$",
      "violations": [
        {"index": 1, "name": "auth.switch-tenant", "reason": "invalidCommandName"}
      ]
    }
  }
}
```

`details.reason` also has `commandsNotAnArray` and `catalogSourceFailed` (the consumer callback
threw; `details.error` gives only the exception type name, never the message). Per-row `reason`
also has `duplicateCommandName` and `missingCommandName` (when there is no name to echo, only the
`index` is given). Command names are protocol vocabulary rather than consumer data, so they are
named directly. Invalid names, duplicates, and missing names are all reported at once, not stopped
at the first one. A violating catalog carries **no `commands`** — skipping the bad rows and serving
the rest would hide a consumer bug as "the app is missing a capability".

## Admission Envelope and Fact Sources

The outer envelope expresses only whether the handler accepted the request:

```json
{
  "schemaVersion": 1,
  "requestId": "request-1",
  "admission": "accepted",
  "payload": {},
  "jobId": null,
  "rejection": null
}
```

`accepted` does not mean the business operation completed, the device executed, or the UI is
correct. The protocol adds no easily misread outer `ok`, `success`, or `executed` field. Business
results go into the payload or the job's terminal state.

Observed values use the following fact sources:

| Source | Meaning |
|---|---|
| `appRecorded` | App-local bookkeeping or a request receipt |
| `commandEcho` | A command echo, not external state |
| `deviceReported` | Reported by the device, or a verifiable read-back |
| `uiObserved` | Direct observation of a Flutter target, metrics, or the render tree |
| `unknown` | Insufficient evidence right now |

A `source` on an object can be inherited by its descendants, and deeper fields may override it. A
descriptor's `factSources` is the closed set of possible sources; the `source` on the actual
payload is the fact for that particular result. Neither the transport layer nor the CLI may
upgrade a weak source into a strong conclusion.

## Command Declarations and Gates

`PatchbayCommandDescriptor` is the source of truth for CLI help, parameter validation, and
side-effect notices. It describes at least:

- the stable full command name and a summary;
- the `readOnly`, `immediate`, or `job` mode;
- parameter types, requiredness, defaults, and enums;
- the consumer gate IDs;
- a `none`, `appState`, or `external` side effect;
- the sensitive-parameter policy and the fact sources that may appear.

Enforcement of `sensitive: true` is done by the host, not by the consumer's handler. The client
marks a value as coming from no-echo stdin with `inputWasStdin`; the host validates against the
catalog declaration before dispatch and strips that meta key out of the arguments, so
`PatchbayInvocationSource` never receives it. If any sensitive parameter has a non-empty value but
lacks that marker, the host rejects with `sensitiveInputRequiresStdin` and `details.parameters`
lists the offending parameter names. A hand-written adapter neither needs to exempt the key in a
parameter allowlist nor **may** reimplement this stdin check itself — after the key is stripped,
such a check is always false.

The one exception is commands with `plane: flutterUi`: that plane is served by
`patchbay_flutter`'s own bridge, where sensitivity is per target (`PatchbaySensitivePolicy.redacted`,
obscured Semantics nodes) rather than per parameter, which a descriptor cannot express — so the
meta key is passed through to that bridge. Consumers on the domain plane are unaffected.

The catalog is the single source of truth for this policy. When the host cannot read a **usable**
catalog it fails closed (failing to read it counts the same as reading an invalid one): calls with
arguments are rejected with `providerProtocolViolation` (`reason: catalogUnavailable`),
`details.catalog` carrying the catalog's own violation reason verbatim, and unvalidated arguments
are never handed to the adapter. Argument-free calls do not consult the catalog — there is no meta
key to strip, and no transmitted value that could be sensitive. Descriptor-declared defaults are
not subject to this check: the marker describes the origin of a **transmitted value**, and the
app's own defaults never went over the wire.

Every invocation passes the mandatory base gate first, then the consumer gates declared by the
descriptor:

```dart
final gates = PatchbayGateEvaluator(
  baseGate: () => const PatchbayGateDecision.allow(),
  consumerGate: (id) => evaluateConsumerGate(id),
);
```

The base gate does not guess login, privacy consent, dependency readiness, or device state on the
app's behalf. Commands that trigger network, file, permission, or external device actions must
declare the corresponding gates explicitly. Service extensions have no symmetric deregistration,
so handlers must still fail closed on every call once state has been revoked.

## Long-Running Work

Long operations must not masquerade as immediate commands. The basic contract of
`PatchbayJobRegistry` is:

1. admission returns a `jobId`;
2. a job emits a `running` event first, then enters a single terminal state;
3. every event has a monotonic sequence, timestamp, phase, source, and payload;
4. cancellation terminates only that job — it does not imply the external system has stopped;
5. when the app or isolate disappears, the client closes out via connection termination rather
   than fabricating an app-side job terminal state.

By default the registry allows at most 32 concurrently running jobs and retains the 200 most
recently settled ones; both are adjustable at construction but must be finite positive integers.
On reaching the running limit, `start()` throws `PatchbayJobCapacityExceeded` before starting the
body, and the consumer should convert that into a stable admission rejection. Cancellation
callbacks wait at most 5 seconds by default; on timeout the job stays running, because "the
cancellation request timed out" does not prove the underlying operation stopped.

With no cancellation callback provided, `cancel()` returns `false` and the job stays running. A
callback returning normally means the consumer confirms the underlying operation has stopped; if
the controller's API only means "a cancellation request was sent", the adapter must keep waiting
for the real cancellation terminal state rather than returning from the callback immediately.

`cancelAll()` initiates cancellation of all running jobs in parallel: every callback is invoked
first, then each converges under its own `cancellationTimeout`, so one hung or throwing callback
consumes a single timeout without blocking or interrupting the rest. The return value is a
per-job `PatchbayJobCancelOutcome` (`cancelled` / `notCancellable` / `timedOut` / `callbackFailed`
/ `alreadySettled`), covering only the jobs still running when it was called; jobs that time out,
throw, or have no callback stay running, and jobs that already settled on their own keep their own
terminal state rather than being rewritten as cancelled.

The theoretical upper bound on observable records in the registry is therefore
`maxRunningJobs + retainedJobs`. `runningJobs`, `settledJobs`, and `totalJobs` are useful for
consumer health checks, but are not a substitute for evidence of business completion.

If the consumer's async API only means "the request has been sent", you cannot mark `completed`
when that Future returns; you must keep observing domain state until the app can give a real
terminal state. `suggestedWaitTimeoutMs` only suggests an observation window to the client — it
does not change completion semantics.

## Logs and Blobs

`PatchbayLogSource` is a query interface injected by the consumer; it does not take over or
duplicate the app's logging pipeline. The consumer performs schema-aware redaction first, then
constructs a `PatchbayRedactedLogRecord`. Core additionally rejects common sensitive field names
and credential shapes, but this is only a defensive layer — it does not replace the app's own
privacy policy.

Log query / tail are bounded by record count, encoded byte size, and time limits. Log export and
Flutter capture share `PatchbayMemoryBlobStore`; responses return only metadata and a `blobId`,
with the binary read in chunks via offset / limit and validated against TTL, capacity, and SHA-256.

## Wire Contract and Generated Code

Stable DTOs — descriptors, invocations, jobs, UI targets, and so on — are generated from a JSON
contract. The generated code handles field names, enums, nested structures, unknown-field
rejection, and JSON type validation; the consumer still hand-writes the semantic projection from
domain object to wire DTO.

Generation and drift checking inside the repository:

```console
$ dart run packages/patchbay/bin/wire_codegen.dart \
    --contract packages/patchbay/contracts/core_wire.json \
    --output packages/patchbay/lib/src/generated/core_wire.g.dart --write
$ dart run packages/patchbay/bin/wire_codegen.dart \
    --contract packages/patchbay/contracts/core_wire.json \
    --output packages/patchbay/lib/src/generated/core_wire.g.dart --check
```

For the contract format and how dependents use it, see
[wire-contract-v1.md](contracts/wire-contract-v1.md) (currently in Chinese).

## Command Contract and Generated Code

`command_codegen` is for **consumers**: write your own command table as a contract
(`contractVersion: 2`) and it generates typed command ids, argument readers, descriptors, and a
dispatch surface. It generates none of this repository's own code.

The repository carries a runnable sample contract and its generated output, and CI's
`codegen_drift` runs `--check` against it — so if a change to the generator makes the output drift,
it goes red here rather than only surfacing after a consumer upgrades their pin:

```console
$ dart run packages/patchbay/bin/command_codegen.dart \
    --contract packages/patchbay/contracts/example_commands.json \
    --output packages/patchbay/contracts/example_commands.g.dart --check
```

Unlike `wire_codegen`, this one behaves **the same from any directory**: the header of the
generated file records a path relative to the generated file itself, not to the calling directory.

## Release Boundary

Consumers must use compile-time constants to make the host, adapters, and registration calls
unreachable in release — hiding the entry point behind a runtime flag is not enough. `patchbay`
provides no release back door or remote re-enable mechanism.

Core cannot prove, on behalf of an arbitrary app, that no debug symbols exist in the final AOT
artifact. Consumers need to scan and sign off on release artifacts in their own build chain;
cross-build-mode semantics of Flutter Keys are `patchbay_flutter`'s responsibility.

## Consumer Responsibilities

- Reuse the existing runtime and controllers; do not build a second state machine for the CLI;
- Keep snapshots read-only over existing state; do not implicitly start subscriptions or external
  actions;
- Concurrency permits, leases, generations, and cancellation ownership still belong to the app;
- Redact sensitive values before they enter Patchbay;
- Label UI observations, app state, and external device results with their respective sources;
- Validate platform behavior and side-effecting domain commands against real-device results.

## Non-Goals

- No coordinate-driven or cross-app black-box automation;
- Not a replacement for widget tests, integration tests, DevTools, or manual acceptance;
- No handling of system permission dialogs, install / uninstall, shells, or other apps;
- CLI output is never promoted to complete product acceptance evidence;
- No release support, and no implicit downgrade path.

## Verification

```console
$ dart pub get
$ dart analyze --fatal-infos
$ dart test
```
