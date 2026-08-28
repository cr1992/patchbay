# Patchbay CLI

English | [简体中文](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_cli/README.zh-CN.md)

`patchbay_cli` is Patchbay's consumer-neutral command line client. It connects to a running
Dart/Flutter app and invokes commands based on the catalog that app actually returns — with no
dependency on consumer code and no local copy of the domain commands.

For the protocol, lifecycle, and transport boundaries see
[`../patchbay/README.md`](https://github.com/cr1992/patchbay/blob/main/packages/patchbay/README.md); for the Flutter UI control plane see
[`../patchbay_flutter/README.md`](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_flutter/README.md).

## Install and Run

Install the CLI from pub.dev and pin the version used by the app:

```console
$ dart pub global activate patchbay_cli 0.5.0
$ export PATH="$PATH":"$HOME/.pub-cache/bin"   # it installs here, but that is not on PATH by default
$ patchbay --help
```

For the trade-offs between the three installation forms — including prebuilt release binaries,
their runtime requirements, and the trap that running
`dart run patchbay_cli:patchbay` inside a consumer's repository directory resolves to the version
that repo pins — see [the installation section of the usage guide](https://github.com/cr1992/patchbay/blob/main/docs/guide.md#安装)
(currently in Chinese). When changing the CLI itself, `dart run tool/build_cli.dart` compiles the
current working tree into an AOT executable, with the output landing in `build/`.

The examples below consistently write `dart run bin/patchbay.dart` (the in-package development
form); after a global install, substitute `patchbay` for it.

## Process Model and Workflow Choice

<p align="center">
  <img src="https://raw.githubusercontent.com/cr1992/patchbay/main/docs/assets/patchbay-cli-workflows.svg" width="100%" alt="Lifecycle of Patchbay one-shot commands, repl, and launch">
</p>

The app and CLI have separate lifecycles: ordinary commands make one request and exit while the app
keeps running; `repl` only reuses a connection; `launch` only starts, discovers, and supervises the
app/session. `launch` and `repl` are complementary. `logs tail` is also a bounded long-poll, not an
endless `tail -f`.

The exact choices, exit conditions, and two-terminal example have one source of truth:
[Choose a workflow](https://github.com/cr1992/patchbay/blob/main/docs/guide.md#先选工作流).
This package README deliberately does not duplicate that table.

## Dart Entry Points

The stable way to drive Patchbay is the executable plus `--json`. Two small Dart libraries exist
for the cases where a process boundary is genuinely in the way, and together they are the whole
public source surface of this package — everything else lives under `lib/src/` and is an
implementation detail that changes without notice.

```dart
// Run one CLI invocation in-process and read its exit code.
import 'package:patchbay_cli/patchbay_cli.dart'; // runPatchbayCli, PatchbayExitCode

// Hold a connection open from Dart instead of shelling out per command.
import 'package:patchbay_cli/patchbay_client.dart';
// PatchbayClient, PatchbaySnapshotDiffClient, PatchbayRuntimeIdentity,
// PatchbayProtocolException, PatchbayTransportException, PatchbaySnapshotRequest,
// connectPatchbayVmService, connectPatchbayDirect
```

Launcher, session, trace, doctor, repl, manifest and permission-driver implementations are not
importable: drive them through CLI commands and their stable JSON. An app started outside
`patchbay launch` registers its session with `patchbay session register` instead of writing the
session record itself.

## Command Reference

Viewing help does not discover sessions, connect to the app, or read a bearer / sensitive stdin:

```text
dart run bin/patchbay.dart --help
dart run bin/patchbay.dart help
dart run bin/patchbay.dart help navigation
dart run bin/patchbay.dart help job
dart run bin/patchbay.dart help ui
dart run bin/patchbay.dart logs --help
dart run bin/patchbay.dart ui widget-tree --help
dart run bin/patchbay.dart help navigation.go     # protocol names from the catalog are topics too
dart run bin/patchbay.dart help ui.wait           # lists every command sharing one protocol name
dart run bin/patchbay.dart help navigate          # alias spelling, expands to the existing path
```

A help topic accepts three spellings: the CLI path (`ui wait`), the catalog protocol name
(`navigation.go`, `ui.semantics.tap`), and aliases (`navigate` / `nav` / `wait` / `tap` / `text` /
`semantics`, plus condition names in the `ui wait <condition>` form). Aliases are just another
spelling of an existing declaration — they add no commands and change no stable name; a protocol
name that no declaration ships is still an `unknown help topic`.

<!-- PATCHBAY_COMMAND_REFERENCE:START -->
This table describes syntax shipped by this CLI. Protocol-backed rows come from repository descriptors; client and local rows remain explicit CLI declarations. It is not the runtime capability catalog; use `patchbay catalog` for actual availability.

| CLI syntax | Declaration source | Protocol command |
|---|---|---|
| `patchbay blob get <blob-id> --output <path>` | client CLI declaration | `blob.metadata` |
| `patchbay blob metadata <blob-id>` | client CLI declaration | `blob.metadata` |
| `patchbay capture diff <before-blob-id> <after-blob-id>` | client CLI declaration | `ui.capture.diff` |
| `patchbay capture root --output <path>` | protocol descriptor | `ui.capture` |
| `patchbay capture target <target-id> <generation> --output <path>` | protocol descriptor | `ui.capture` |
| `patchbay catalog` | client CLI declaration | — |
| `patchbay describe <service-command>` | local CLI declaration | — |
| `patchbay doctor` | local CLI declaration | — |
| `patchbay doctor permission` | local CLI declaration | — |
| `patchbay exec <service-command>` | client CLI declaration | — |
| `patchbay identity` | client CLI declaration | — |
| `patchbay job cancel <job-id>` | client CLI declaration | `patchbay.job.cancel` |
| `patchbay job get <job-id>` | client CLI declaration | `patchbay.job.get` |
| `patchbay launch -- <consumer command>` | local CLI declaration | — |
| `patchbay logs export --output <path>` | client CLI declaration | `logs.export` |
| `patchbay logs query` | client CLI declaration | `logs.query` |
| `patchbay logs tail` | client CLI declaration | `logs.tail` |
| `patchbay navigation back [--revision <revision>]` | protocol descriptor | `navigation.back` |
| `patchbay navigation catalog` | protocol descriptor | `navigation.catalog` |
| `patchbay navigation current` | protocol descriptor | `navigation.current` |
| `patchbay navigation go <destination-id> [--revision <revision>]` | protocol descriptor | `navigation.go` |
| `patchbay navigation push <destination-id> [--revision <revision>]` | protocol descriptor | `navigation.push` |
| `patchbay net profile` | client CLI declaration | — |
| `patchbay perf profile [--duration-ms <ms>] [--sample-limit <events>]` | client CLI declaration | — |
| `patchbay permission capabilities` | local CLI declaration | — |
| `patchbay permission exercise <permission> --decision <decision>` | local CLI declaration | — |
| `patchbay permission fail <permission> --state <state>` | local CLI declaration | — |
| `patchbay permission normalize <permission> --state <state>` | local CLI declaration | — |
| `patchbay permission reset <permission>` | local CLI declaration | — |
| `patchbay permission status <permission>` | local CLI declaration | — |
| `patchbay repl` | client CLI declaration | — |
| `patchbay session register --ws-uri <uri> --application-id <id> --device-id <id> --process-id <pid> [<session-id>]` | local CLI declaration | — |
| `patchbay session unregister <session-id>` | local CLI declaration | — |
| `patchbay session use <session-id> \| --clear` | local CLI declaration | — |
| `patchbay sessions list` | local CLI declaration | — |
| `patchbay sessions prune` | local CLI declaration | — |
| `patchbay snapshot [--path <dot.path>]` | client CLI declaration | — |
| `patchbay snapshot diff --from <revision>` | client CLI declaration | — |
| `patchbay snapshot wait <dot.path> --until <condition> [<json-value>]` | client CLI declaration | — |
| `patchbay trace diff <before-trace-id> <after-trace-id>` | local CLI declaration | — |
| `patchbay trace export <trace-id> --output <directory>` | local CLI declaration | — |
| `patchbay trace mark <note>` | local CLI declaration | — |
| `patchbay trace prune [--dry-run]` | local CLI declaration | — |
| `patchbay trace show <trace-id>` | local CLI declaration | — |
| `patchbay trace start --name <name> [--activate] [--pin]` | local CLI declaration | — |
| `patchbay trace stop [trace-id]` | local CLI declaration | — |
| `patchbay ui action <identifier> <generation> <action> [text]` | protocol descriptor | `ui.semantics.actionByIdentifier` |
| `patchbay ui focus-tree [--output <path>] [--force] [--max-inline-bytes <n>]` | client CLI declaration | — |
| `patchbay ui gesture drag <identifier> <generation> --start <json> --gesture-path <json> [--duration-ms <ms>]` | protocol descriptor | `ui.gesture.drag` |
| `patchbay ui gesture fling <identifier> <generation> --start <json> --velocity <json> [--duration-ms <ms>]` | protocol descriptor | `ui.gesture.fling` |
| `patchbay ui gesture press-hold <identifier> <generation> --start <json> [--duration-ms <ms>]` | protocol descriptor | `ui.gesture.pressHold` |
| `patchbay ui gesture tap <identifier> <generation> [--start <json>]` | protocol descriptor | `ui.gesture.tap` |
| `patchbay ui inspect off` | protocol descriptor | `ui.inspect.select` |
| `patchbay ui inspect on [--ttl-ms <ms>]` | protocol descriptor | `ui.inspect.select` |
| `patchbay ui inspect status` | protocol descriptor | `ui.inspect.status` |
| `patchbay ui keep-awake off` | protocol descriptor | `ui.keepAwake.set` |
| `patchbay ui keep-awake on [--lease-ms <ms>]` | protocol descriptor | `ui.keepAwake.set` |
| `patchbay ui keep-awake status` | protocol descriptor | `ui.keepAwake.status` |
| `patchbay ui render-tree [--output <path>] [--force] [--max-inline-bytes <n>]` | client CLI declaration | — |
| `patchbay ui reveal <identifier> [--container <identifier>] [--direction <forward\|backward\|both>] [--max-steps <n>] [--timeout-ms <ms>]` | protocol descriptor | `ui.reveal` |
| `patchbay ui semantics action <node-id> <generation> <action> [text]` | protocol descriptor | `ui.semantics.action` |
| `patchbay ui semantics tree [--output <path>] [--force] [--max-inline-bytes <n>]` | protocol descriptor | `ui.semantics.tree` |
| `patchbay ui tap <identifier> [--generation <generation>]` | protocol descriptor | `ui.semantics.tap` |
| `patchbay ui targets --emit-manifest` | local CLI declaration | — |
| `patchbay ui text enter <target-id> <generation> [text]` | protocol descriptor | `ui.text.enter` |
| `patchbay ui text set <target-id> <generation> [text]` | protocol descriptor | `ui.text.set` |
| `patchbay ui verify-manifest <manifest-file> [--navigate] [--continue-on-error] [--restore]` | local CLI declaration | — |
| `patchbay ui wait destination <destination-id>` | protocol descriptor | `ui.wait` |
| `patchbay ui wait frame-revision <revision>` | protocol descriptor | `ui.wait` |
| `patchbay ui wait semantics-mounted <identifier>` | protocol descriptor | `ui.wait` |
| `patchbay ui wait semantics-unmounted <identifier>` | protocol descriptor | `ui.wait` |
| `patchbay ui wait semantics-value <identifier> <value>` | protocol descriptor | `ui.wait` |
| `patchbay ui wait tree-revision <revision>` | protocol descriptor | `ui.wait` |
| `patchbay ui widget-tree [--output <path>] [--force] [--max-inline-bytes <n>]` | client CLI declaration | — |
<!-- PATCHBAY_COMMAND_REFERENCE:END -->

Once the app is launched by the `flutter run --machine` launcher, the CLI discovers the unique
current session from the user's temp directory by default:

```text
dart run bin/patchbay.dart --json identity
dart run bin/patchbay.dart --json catalog
dart run bin/patchbay.dart --json snapshot
dart run bin/patchbay.dart --json exec <namespace.command>
```

To make startup and recovery one bounded operation, launch an integrated consumer through the CLI:

```text
dart run bin/patchbay.dart launch -- flutter run --vmservice-out-file .dart_tool/patchbay/vmservice.txt
dart run bin/patchbay.dart --keep-awake launch -- flutter run ...
PATCHBAY_KEEP_AWAKE=true dart run bin/patchbay.dart launch -- flutter run ...
dart run bin/patchbay.dart --no-keep-awake launch -- flutter run ...
```

The child reads `PATCHBAY_SESSION_DIR`, `PATCHBAY_LAUNCH_ID`, and
`PATCHBAY_LAUNCH_OWNER_PID` with `PatchbayLaunchContext.tryFromEnvironment`, then writes the full
pending record using `pendingRecord` and adds its transport with `withTransport`. The launcher does
not invent application/device metadata: the child must pass the real consumer/App `processId`,
which is distinct from the launcher `ownerPid`. It also does not parse a private stdout frame. It supervises only a record
whose launch ID and owner PID both match; a child that does not declare one fails in bounded time as
`sessionNotDeclared`. Machine frames stay on stdout and child/human output is forwarded to stderr.
Stable live sessions are observed every five seconds; a disconnect restarts recovery at the initial
200 ms backoff, and each identity probe is bounded by both child exit and the remaining budget.

The screen-awake policy is off by default. Global `--keep-awake`, or a local
`PATCHBAY_KEEP_AWAKE=true/on/1`, acquires the existing ten-minute lease only after the launcher is
`live` and renews it at half-lease through the existing health observation. `--no-keep-awake`
overrides that local default. Successful one-shot / REPL commands may renew under the same policy,
while explicit `ui keep-awake on|off|status` commands never trigger a second implicit operation.
Terminal paths and signal cancellation attempt release; on disconnect the machine frame / JSON says
`releaseUnconfirmed` or `renewalUnconfirmed`, with App-side lease expiry remaining the final fallback.

When any of the steps above does not work, run the health check first — it dials out itself, so a
failed connection is one of its findings rather than the end of the command:

```text
dart run bin/patchbay.dart doctor          # session / connection / catalog / lifecycle, item by item
dart run bin/patchbay.dart --json doctor
```

The four items are checked in dependency order, each giving "symptom → possible cause → suggested
action", and once one fails the rest are marked `skipped`. The exit code takes the category of the
first failure (session / connection `3`, catalog `4`, lifecycle `5`); with warnings only it is `0`.
It also reads a snapshot once, and on finding any boolean `active` set to `true` it prints the path
and advises against `force-stop` / `kill` — there may be a live business session on the device. For
the full semantics see [`../../docs/guide.md`](https://github.com/cr1992/patchbay/blob/main/docs/guide.md) (currently in Chinese).

With several apps or worktrees running at once, it does not guess by PID, timestamp, or current
directory. The CLI fails closed with `sessionAmbiguous` and prints the session IDs without URIs;
the caller must choose explicitly:

```text
dart run bin/patchbay.dart --session <session-id> --json identity
```

`--ws-uri` remains the recovery path for when the launcher record is lost:

```text
dart run bin/patchbay.dart --ws-uri <uri> --json identity
dart run bin/patchbay.dart --ws-uri <uri> --json catalog
dart run bin/patchbay.dart --ws-uri <uri> --json snapshot

# Compare the current full snapshot with a retained host-observed revision.
dart run bin/patchbay.dart --ws-uri <uri> --json snapshot diff --from 7
dart run bin/patchbay.dart --ws-uri <uri> --json exec <namespace.command>
```

`<generation>` comes from the most recent catalog or Semantics tree. It changes when a target
remounts; a write carrying a stale value is rejected stably, so a command cannot land on a new
instance that happens to share the name.

When `--revision` is omitted from `navigation go|push|back`, the CLI first calls
`navigation.current` to read the current revision, then dispatches, and the result carries
`revisionSource: navigation.current`. The fence is unchanged: the revision still goes out with the
request, and if navigation moved between the read and the dispatch, the app still blocks it with a
stable rejection. An explicit `--revision` keeps the original behavior — no extra read, and no such
marker.

The `ui wait <subcommand>` names deliberately differ from the `condition` in the payload
(`semantics-mounted` ↔ `semanticsMounted`, `destination` ↔ `navigationDestination`). Both spellings
can be typed directly, and the mapping table is in `patchbay help ui wait`; neither set of names
will change, because they are wire contracts.

### Bounded VM Performance Profile

`perf profile` samples the connected VM Service for 10 seconds by default and emits only the
stable `patchbay.performanceProfile.v1` summary: build/raster frame durations and 16 ms jank counts,
two heap observations, and new/old-generation GC counts. `--duration-ms` is limited to 1..60000 and
`--sample-limit` to 1..10000. At most 10000 events and 8 MiB of processed event data contribute to
one result; either limit sets `sampling.truncated=true` and reports the dropped count. Timeline
events are reduced as public VM stream batches arrive, and the subscription is cancelled at the
first limit; raw events are never retained or copied into Patchbay output, logs, or artifacts. The command temporarily enables
the public VM timeline streams it needs and restores the previous stream set on success or failure.

This is a VM observation (`factSource=uiObserved`), not an App catalog command. Direct HTTP returns
the stable `profilingVmServiceRequired` code rather than fabricating equivalent facts. Older VMs
that do not expose the required public RPCs/streams return `performanceProfilingUnavailable`.

`net profile` currently returns `networkProfilingUnavailable` without collecting anything. In the
reviewed `vm_service 15.2.0` API, the public HTTP profile response already contains bodies, headers,
cookies, and query values before the caller can filter it. Collecting that response and redacting
afterwards would violate Patchbay's collection-time privacy boundary, so no network capability is
published until a public pre-filtered RPC or an injected privacy-safe collector exists.

`ui tap <identifier>` is a one-step replacement for `ui semantics tree` + `ui semantics action`:
resolution, generation checking, and dispatch all happen in one pass on the app side, so the CLI
neither constructs a nodeId nor supplies a default generation. `--generation` is optional; passing
it makes it the caller's own up-front fence, and omitting it leaves the fence to the generation the
bridge pins before the gates. Misses, ambiguity, and stale generations are all stable rejections
with details (respectively: the list of mounted identifiers, the candidate list, and
expected/current), so an empty rejection never pushes the caller back to a whole-tree dump.

`ui action <identifier> <generation> <action> [text]` provides the same one-request resolution for
the other public Semantics actions. Here the caller generation is required and is checked before
and after policy/gate evaluation. The command exposes only tap, focus, four-direction scroll, and
setText; it never accepts `latest` or retries against a replacement node. Sensitive setText input
uses the global `--stdin` flag.

### UI Target Declaration Reconciliation

`ui verify-manifest <file>` reads a JSON or YAML manifest maintained by the consumer and reconciles
`catalogTarget` entries against the catalog's `uiTargets` and `semanticsIdentifier` entries against
the existing live `ui.semantics.tree`, reporting three classes of discrepancy: `declaredNotMounted`,
`mountedNotDeclared`, and `propertyMismatch`. The comparison happens entirely on the CLI side: it
adds no wire command and uses only the existing catalog/tree surfaces; when a `destination` appears in the manifest, it
additionally reads `navigation.current` once for scope filtering. For the schema, field semantics,
`destination` filtering rules, and the "not mounted ≠ missing" boundary, see the
[usage guide](https://github.com/cr1992/patchbay/blob/main/docs/guide.md#ui-目标声明对账ui-verify-manifest) (currently in Chinese); the
example file is at
[`docs/examples/ui-targets-manifest.json`](https://github.com/cr1992/patchbay/blob/main/docs/examples/ui-targets-manifest.json).

Full agreement exits `0`; any class of discrepancy in the report exits `7` — the app side answered
everything normally, so it is neither a rejection (`5`) nor a typed failure (`6`). An unreadable or
invalid manifest fails closed with exit code `64`, and `--json` gives `manifestInvalid` /
`manifestUnreadable` plus a `details.field` pointing at the exact location. Input format is selected
only by a lowercase `.json`, `.yaml`, or `.yml` extension; unknown extensions are not sniffed. YAML
uses safe parsing without recovery, aliases, or explicit tags, and both formats share the 1 MiB,
64-level, and 200,000-node parser budgets (mapping keys included). Syntax errors include one-based `line` / `column` without
echoing file content. Human-readable output
lists the discrepancy entries directly; inside `repl` each line takes only one line and reports
counts.

`--navigate` is the explicit side-effecting walkthrough mode. It visits v2 destinations in manifest
order, asks only for destination ids declared by `navigation.catalog`, confirms each arrival with the
closed `ui.wait navigationDestination` condition, and then runs the same reconciliation. Per-screen
and total budgets default to 5 s and 120 s (`--screen-timeout-ms`, max 120 s;
`--total-timeout-ms`, max 10 min). It stops after the first failure unless
`--continue-on-error` is present. `--restore` makes a bounded best-effort return to the initial
destination; a restore failure is a machine-readable notice and never replaces the walkthrough exit
code. The JSON report preserves `visited`, `passed`, `failed`, `skipped`, per-screen `reasonCode`, and
`finalDestination`. Hosts without the complete declared navigation surface retain current-screen
verification and report `navigationMode: unavailable`; the CLI never probes support by interpreting
an error shape.

Manifest v2 keeps the namespaces independent: `kind` / `sensitive` are valid only for
`catalogTarget`, while `semanticsIdentifier` stores only its stable identifier. A unique live match
reports the observed `nodeId`, `generation`, and tree revision; no match is `declaredNotMounted`, and
multiple matches fail closed as `uiSemanticsIdentifierAmbiguous`. Missing capability, truncated tree,
and malformed tree payloads have distinct stable protocol codes. `ui targets --emit-manifest`
includes unique live identifiers when the App declares the tree capability, but refuses ambiguous or
cross-namespace IDs instead of inventing a representative.

### repl Sessions

```text
dart run bin/patchbay.dart --ws-uri <uri> --json repl <<'EOF'
identity
describe ui.capture
ui semantics tree
ui tap login.submit
EOF
```

`repl` opens one connection and then executes typed commands line by line, with exactly the same
syntax as one-shot invocations. Each line's output carries its own `exitCode` (under `--json`, one
JSON envelope per line; otherwise `[n] exit=<code> <summary>`): a process exit code cannot carry
per-line results, so the session code describes only the session itself — `0` for a clean run, or
the category of the error that terminated it.
`describe <service-command>` can run inside the session to read the live catalog row without
invoking the command it describes.

A rejected or typed-failure line does not end the session; transport / protocol / session errors
do, because they mean the reused connection or the peer is no longer the one the operator selected,
and the CLI will not silently reconnect.

The following fail closed inside `repl` rather than being silently ignored: connection options and
`--json` (they belong to the session, and honoring them per line would require reconnecting),
`--stdin` (the command stream already occupies stdin, leaving no no-echo channel), and a nested
`repl`. Direct mode does not enter `repl` at all: the bearer token would compete with the command
stream for the same stdin. Blank lines and lines starting with `#` are skipped, and `exit` / `quit`
or closing stdin ends the session.

### Command Declaration Consistency

`PatchbayFriendlyCommand` is the CLI's single command table: path resolution, argument
construction, dispatch, and help are all derived from it. Each declaration picks one
`PatchbayCommandTarget`, and `runPatchbayCli` switches over that enum with no default, so a new
command cannot be wired for execution while missing its help. `exec`'s protocol name comes from the
caller's argument; identity / catalog / snapshot and the three diagnostic trees go through
transport methods rather than catalog commands, and those differences are written into the
declarations too.

Every command (including `exec`, `job`, `ui text`, `ui semantics`, and the three diagnostic trees)
fails closed on irrelevant options: passing an option that command does not accept reports
`--<name> is not valid for <command>` with exit code `64` instead of ignoring it silently.

A friendly command is only a generic argument mapping onto a stable protocol name — not a second
capability list. The CLI still reads the app's current catalog on every execution; when the catalog
and the invoke result contradict each other it returns `catalogInvocationDrift` (with `details`
carrying the host's own catalog violation reason, so you need not run `catalog` again just to learn
which command name was invalid), and a missing command still preserves the app's
`commandNotRegistered` rejection and exit code `4`. The CLI never infers capabilities from the
number of commands. The full command name remains the protocol identity, and arbitrary consumer
commands continue to use `exec <namespace.command>`.

`describe <namespace.command>` reads that catalog only; it never invokes the command. Its JSON
answer contains the complete command row, `schemaMode`, and the closed `retryEligibility` value
`eligible`, `notDeclared`, or `notExternal`. When an external row declares a valid `retryPolicy`,
the CLI retries only transport-unavailable/timeout failures, reusing one `requestId` for every
attempt. App rejections, protocol failures, and any provider response are final and are never
retried.

Every RPC round trip has a budget, 30 seconds by default, adjustable with
`--transport-timeout-ms` and applying to both transports; on exhaustion it fails with exit code `3`
and the stable code `appUnresponsive` plus a remediation hint. `--timeout-ms` is the business wait
budget sent to the app, and a request that declares it widens this RPC's budget to "the declared
wait plus one round trip" so it is not cut short by the default.

Log filtering supports `--cursor`, `--direction`, `--limit`, comma-separated `--levels`/
`--categories`, and ISO-8601 `--since`/`--until`. Capture supports `--pixel-ratio`,
`--after-frames` (1..120 Patchbay-observed Flutter frames), and `--timeout-ms`. If the host does
not declare `captureAfterFrames`, the CLI omits that field and labels the response
`captureMode=legacyImmediate`; it never guesses support from an error. `capture diff` compares two
retained capture blob IDs of the same size and pixel format and returns counts plus a ratio, not a
pass/fail verdict. Every artifact download first writes a temp file in the same directory and
validates blob metadata, offsets, base64, total length, and SHA-256 chunk by chunk, renaming only
after everything passes; an existing output is refused by default and replaced only with an
explicit `--force`. Expiry, rejection, out-of-order chunks, hash errors, and interruptions never
leave a partial file under the final output name.

## Connection Boundary

`--ws-uri` may contain VM Service authentication material:

- take it only from trusted launcher output or the current debug session;
- never write it into scripts, logs, snapshots, or anything you commit;
- CLI errors report only the error category, never echoing the full URI.

The participating child first writes a provisional record via atomic replace, then fills in the URI
once its own toolchain discovers it; only after the launcher connects and reads `ext.patchbay.identity` are
`appInstanceId` and `isolateId` filled in. A complete record binds the session schema,
`applicationId`, `appInstanceId`, `isolateId`, launcher PID, `wsUri`, build mode, creation time,
worktree, and device ID. Records live in the current user's system temp directory by default, and
`PATCHBAY_SESSION_DIR` can override that. `patchbay launch` forwards child stdout/stderr as human
output on stderr; stdout remains a stream of stable launcher machine frames.

A live PID only means the launcher may still be running — it does not prove the app instance is
still the same one. A dead PID or schema/identity mismatch invalidates the record; a temporarily
unreachable endpoint remains available for bounded recovery. On hot restart the launcher observes
the changed App instance and re-pins the record before reuse. An explicit `--ws-uri` runs the same
schema/isolate/appInstance identity check. The launcher deletes only pending records it owns on
exit. On POSIX the directory and files are tightened to
`0700` and `0600` respectively, and ordinary output, errors, and selection lists never contain a
URI or token.

The current command execution path does not itself call ADB. On Android, however, if the URI came
from `flutter run`, Flutter's own launch, install, and port forwarding may still use ADB
indirectly — so the VM Service path cannot claim to be end-to-end ADB-free.

The CLI can also connect to a `patchbay_transport` direct host that the consumer started
explicitly. A direct host performs no discovery, so the caller must obtain the endpoint, runtime
identity, and short-lived bearer through a trusted out-of-band channel; the token can only be read
from no-echo stdin, as the CLI provides no argv/env/query entry point for it:

```text
dart run bin/patchbay.dart \
  --direct-endpoint http://192.0.2.10:12345/patchbay/direct/v1 \
  --direct-token-stdin \
  --direct-application-id dev.example.app \
  --direct-app-instance-id <instance-id> \
  --json identity
# here the CLI reads one line from the current TTY without echoing it
```

The example above is the interactive TTY shape; do not put a bearer literal into shell history. The
CLI turns echo off automatically while reading a bearer. Direct LAN is experimental plaintext HTTP:
the bearer provides authentication but not confidentiality, cannot prevent passive listening or
replay on the same network segment, and must not be called a secure channel. Enable it explicitly
only on a trusted, isolated network with a short TTL. The Flutter SDK's widget/render/focus
diagnostic extensions still exist only on the VM Service path.

## Input and Results

Ordinary structured arguments are passed as a JSON object via `--args`, and `--stdin` reads one
no-echo line from stdin. The two can be used together: the JSON object from stdin is merged with
`--args`, with stdin winning on shared keys, so readable arguments stay on the command line and
only secrets go through the no-echo channel. Using `--stdin` without `--args` is still valid (the
degenerate case of that merge), and stdin content that is not a JSON object still errors as before.

Parameters a descriptor marks as sensitive can only come from stdin: if one appears in `--args`,
the CLI refuses to send with exit code `64`, nothing goes on the wire, and the error names only the
parameter without echoing its value. Output retains only redacted metadata. When stdin takes over a
real TTY, the CLI temporarily turns off terminal echo and restores it afterwards; if echo cannot be
turned off, it fails closed with `terminalEchoControlFailed`. Piped input does not modify terminal
modes.

`admission=accepted` only means the app has accepted the request, not that the side effect is
complete. Long-running work returns a `jobId`:

- `--wait` keeps reading until a terminal state;
- `job get` reads the current snapshot;
- `job cancel` requests cancellation, but the cancellation outcome is still whatever job state the
  app returns.

The stable location for `jobId` is the **top level of the response**: both the admission envelope
and the `--wait` terminal result give the job admitted for that command at the top level.
`payload.jobId` is a field the app's own job snapshot carries; both are preserved, and scripts
should read the top-level one.

The CLI generates and sends a `requestId` for every invoke, and both the VM Service and direct
paths require the response to echo the same value; a mismatch exits as a protocol error, so a
concurrent or late response cannot be attributed to the wrong command. An explicitly empty
`requestId` also fails closed.

`--wait` waits at most 60 seconds by default; when the descriptor/admission carries
`suggestedWaitTimeoutMs`, the consumer's suggested observation window is used instead. BLE pairing,
for example, suggests 150 seconds to cover its 120-second activation terminal state. A timeout
means the app accepted the request but produced no terminal state within the observation window,
and is classified as a typed operation failure (exit code `6`), not a connection failure.

When the host catalog has `patchbay.job.wait`, the CLI does a bounded long poll with
`afterSequence` and marks the result `waitMode=serverLongPoll`. Against an older host without that
command, it falls back to compatibility polling on `patchbay.job.get`, with the result explicitly
marked `waitMode=legacyPolling` plus a `waitNotice` — it does not pose as a server-side wait. An
`outcome=timedOut` from `logs tail` is a successful long-poll observation and still exits `0`,
rather than being misreported as a transport error.

JSON output preserves fact sources, rejection codes, job event sequences, and capability warnings.
The CLI does not reinterpret these fields as proof that the device executed successfully, that
pixels are correct, or that system UI was operated.

With `--json`, stdout contains exactly one JSON document: the response envelope, or an error
envelope

```json
{"error": {"code": "sessionAmbiguous", "details": {"sessions": ["…"]}}}
```

whose shape matches the app's rejection envelope (a stable `code` plus free-form `details`). The
`code` for a usage error is `usageError`, with the sentence in `details.message`; session /
protocol / transport / sensitive-input / `waitTimeout` errors use their own stable codes, and the
fallback error exposes only the exception type name, never echoing a URI or token. Human-readable
text still goes only to stderr. Without `--json`, behavior is unchanged.

That count is per one-shot command. Three commands stream instead, and a script reads them one line
at a time rather than as a single document: `repl` emits one envelope per line, `logs tail` emits
NDJSON, and `launch` emits launcher machine frames.

The count also describes stdout on its own. Human sentences go to stderr, and so does whatever
wrapper the command runs under — `just`, `npm`, a shell function — when it announces a non-zero
exit. Merging the two with `2>&1` appends that prose to a document that was already well formed,
and the parser then reports trailing data, which reads like a second document and is not one.
Redirect stderr to a file when you want to keep it; never into the stream being parsed.

The chunk size for artifact downloads is taken from the default `limit` of `blob.read` in the
catalog (capped by the CLI default of 64 KiB) rather than hard-coded: when a consumer lowers
`maxChunkBytes`, downloads still work instead of being killed by `blobInvalidChunkLimit`.

## Exit Codes

| Exit code | Meaning |
|---|---|
| `0` | The request completed, or the app returned a parseable non-error result |
| `3` | Session discovery, connection, transport, or VM Service RPC failed |
| `4` | Incompatible schema/identity, or the command is absent from the catalog |
| `5` | The app adapter or Flutter bridge refused admission |
| `6` | An admitted operation returned `outcome=failed`, a job failed or was cancelled, or waiting for a terminal state timed out |
| `7` | Local reconciliation (`ui verify-manifest`) completed and the report contains discrepancies; every request to the app was answered normally |
| `64` | The command form, arguments, or local input were invalid (including a manifest file that could not be read) |

Callers should read the JSON envelope as well; exit codes do not carry device-level completion.

## Capabilities and Boundaries

The Widget/Render/Focus commands are read-only proxies onto the Flutter SDK's diagnostic
extensions. Their output carries `schema=flutterSdkPassthrough` and its fields change with the
Flutter SDK; when the corresponding extension is absent in profile, they return
`flutterDiagnosticUnavailable` stably. Stable automation should consume the Patchbay schema of
`ui semantics tree`.

Navigation, wait, capture, structured logs, and direct are available only when actually registered
by the runtime catalog / consumer host. The CLI does not paper over missing capabilities via ADB,
coordinate taps, or guessing from widget text, and it will not start a direct listener or
distribute a bearer on the app's behalf. Logs are app records the consumer has already redacted;
capture proves only the composited result of Flutter repaint boundaries, excludes system permission
dialogs, and may be missing PlatformViews.

System permission orchestration is opt-in through an explicit external driver; unsupported device,
runner, signing, and language conditions fail closed. See
[platform permission drivers](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_cli/doc/platform-permission-drivers.md).
For the stable commands, passthrough boundaries, and exit conditions of the three trees and
actions, see
[`../patchbay_flutter/doc/ui-inspection-and-actions.md`](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_flutter/doc/ui-inspection-and-actions.md)
(currently in Chinese).
