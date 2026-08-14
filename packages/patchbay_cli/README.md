# Patchbay CLI

English | [简体中文](README.zh-CN.md)

`patchbay_cli` is Patchbay's consumer-neutral command line client. It connects to a running
Dart/Flutter app and invokes commands based on the catalog that app actually returns — with no
dependency on consumer code and no local copy of the domain commands.

For the protocol, lifecycle, and transport boundaries see
[`../patchbay/README.md`](../patchbay/README.md); for the Flutter UI control plane see
[`../patchbay_flutter/README.md`](../patchbay_flutter/README.md).

## Install and Run

These packages are not published to pub.dev yet; you can install from a repository tag:

```console
$ dart pub global activate --source git https://github.com/cr1992/patchbay.git \
    --git-ref patchbay-v0.2.0 --git-path packages/patchbay_cli
$ export PATH="$PATH":"$HOME/.pub-cache/bin"   # it installs here, but that is not on PATH by default
$ patchbay --help
```

For the trade-offs between the three installation forms — including the prebuilt binaries from
`0.3.0` onward, a startup-time comparison, and the trap that running
`dart run patchbay_cli:patchbay` inside a consumer's repository directory resolves to the version
that repo pins — see [the installation section of the usage guide](../../docs/guide.md#安装)
(currently in Chinese). When changing the CLI itself, `dart run tool/build_cli.dart` compiles the
current working tree into an AOT executable, with the output landing in `build/`.

The examples below consistently write `dart run bin/patchbay.dart` (the in-package development
form); after a global install, substitute `patchbay` for it.

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

Once the app is launched by the `flutter run --machine` launcher, the CLI discovers the unique
current session from the user's temp directory by default:

```text
dart run bin/patchbay.dart --json identity
dart run bin/patchbay.dart --json catalog
dart run bin/patchbay.dart --json snapshot
dart run bin/patchbay.dart --json exec <namespace.command>
```

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
the full semantics see [`../../docs/guide.md`](../../docs/guide.md) (currently in Chinese).

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
dart run bin/patchbay.dart --ws-uri <uri> --json exec <namespace.command>
dart run bin/patchbay.dart --ws-uri <uri> --json --args '{"value":42}' exec <namespace.command>
dart run bin/patchbay.dart --ws-uri <uri> --json --wait exec <namespace.command>
dart run bin/patchbay.dart --ws-uri <uri> --json job get <job-id>
dart run bin/patchbay.dart --ws-uri <uri> --json job cancel <job-id>
dart run bin/patchbay.dart --ws-uri <uri> --json ui text set <target-id> <generation> <text>
dart run bin/patchbay.dart --ws-uri <uri> --json ui text enter <target-id> <generation> <text>
dart run bin/patchbay.dart --ws-uri <uri> --json ui semantics tree
dart run bin/patchbay.dart --ws-uri <uri> --json ui semantics action <node-id> <generation> <action>
dart run bin/patchbay.dart --ws-uri <uri> --json ui tap <identifier>
dart run bin/patchbay.dart --ws-uri <uri> --json --generation <generation> ui tap <identifier>
dart run bin/patchbay.dart --ws-uri <uri> --json ui verify-manifest ./ui-targets.json
dart run bin/patchbay.dart --ws-uri <uri> --json ui widget-tree
dart run bin/patchbay.dart --ws-uri <uri> --json ui render-tree
dart run bin/patchbay.dart --ws-uri <uri> --json ui focus-tree
dart run bin/patchbay.dart --ws-uri <uri> --json navigation catalog
dart run bin/patchbay.dart --ws-uri <uri> --json navigation current
dart run bin/patchbay.dart --ws-uri <uri> --json navigation go settings
dart run bin/patchbay.dart --ws-uri <uri> --json --revision 4 navigation go settings
dart run bin/patchbay.dart --ws-uri <uri> --json --revision 5 navigation push details
dart run bin/patchbay.dart --ws-uri <uri> --json --revision 6 navigation back
dart run bin/patchbay.dart --ws-uri <uri> --json --timeout-ms 5000 ui wait semantics-mounted app.settings
dart run bin/patchbay.dart --ws-uri <uri> --json --timeout-ms 5000 ui wait semantics-unmounted app.loading
dart run bin/patchbay.dart --ws-uri <uri> --json --timeout-ms 5000 ui wait semantics-value app.status ready
dart run bin/patchbay.dart --ws-uri <uri> --json --revision 4 ui wait destination settings
dart run bin/patchbay.dart --ws-uri <uri> --json ui wait tree-revision 10
dart run bin/patchbay.dart --ws-uri <uri> --json ui wait frame-revision 20
dart run bin/patchbay.dart --ws-uri <uri> --json --limit 100 logs query
dart run bin/patchbay.dart --ws-uri <uri> --json --cursor <cursor> --timeout-ms 5000 logs tail
dart run bin/patchbay.dart --ws-uri <uri> --json --output ./logs.ndjson logs export
dart run bin/patchbay.dart --ws-uri <uri> --json --output ./screen.png capture root
dart run bin/patchbay.dart --ws-uri <uri> --json --output ./target.png capture target <target-id> <generation>
dart run bin/patchbay.dart --ws-uri <uri> --json blob metadata <blob-id>
dart run bin/patchbay.dart --ws-uri <uri> --json --output ./artifact.bin blob get <blob-id>
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

`ui tap <identifier>` is a one-step replacement for `ui semantics tree` + `ui semantics action`:
resolution, generation checking, and dispatch all happen in one pass on the app side, so the CLI
neither constructs a nodeId nor supplies a default generation. `--generation` is optional; passing
it makes it the caller's own up-front fence, and omitting it leaves the fence to the generation the
bridge pins before the gates. Misses, ambiguity, and stale generations are all stable rejections
with details (respectively: the list of mounted identifiers, the candidate list, and
expected/current), so an empty rejection never pushes the caller back to a whole-tree dump.

### UI Target Declaration Reconciliation

`ui verify-manifest <file>` reads a JSON manifest maintained by the consumer and reconciles it
against the catalog's `uiTargets`, reporting three classes of discrepancy: `declaredNotMounted`,
`mountedNotDeclared`, and `propertyMismatch`. The comparison happens entirely on the CLI side: it
adds no wire command and uses only the catalog; when a `destination` appears in the manifest, it
additionally reads `navigation.current` once for scope filtering. For the schema, field semantics,
`destination` filtering rules, and the "not mounted ≠ missing" boundary, see the
[usage guide](../../docs/guide.md#ui-目标声明对账ui-verify-manifest) (currently in Chinese); the
example file is at
[`docs/examples/ui-targets-manifest.json`](../../docs/examples/ui-targets-manifest.json).

Full agreement exits `0`; any class of discrepancy in the report exits `7` — the app side answered
everything normally, so it is neither a rejection (`5`) nor a typed failure (`6`). An unreadable or
invalid manifest fails closed with exit code `64`, and `--json` gives `manifestInvalid` /
`manifestUnreadable` plus a `details.field` pointing at the exact location. Human-readable output
lists the discrepancy entries directly; inside `repl` each line takes only one line and reports
counts.

### repl Sessions

```text
dart run bin/patchbay.dart --ws-uri <uri> --json repl <<'EOF'
identity
ui semantics tree
ui tap login.submit
EOF
```

`repl` opens one connection and then executes typed commands line by line, with exactly the same
syntax as one-shot invocations. Each line's output carries its own `exitCode` (under `--json`, one
JSON envelope per line; otherwise `[n] exit=<code> <summary>`): a process exit code cannot carry
per-line results, so the session code describes only the session itself — `0` for a clean run, or
the category of the error that terminated it.

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

Every RPC round trip has a budget, 30 seconds by default, adjustable with
`--transport-timeout-ms` and applying to both transports; on exhaustion it fails with exit code `3`
and the stable code `appUnresponsive` plus a remediation hint. `--timeout-ms` is the business wait
budget sent to the app, and a request that declares it widens this RPC's budget to "the declared
wait plus one round trip" so it is not cut short by the default.

Log filtering supports `--cursor`, `--direction`, `--limit`, comma-separated `--levels`/
`--categories`, and ISO-8601 `--since`/`--until`. Capture supports `--pixel-ratio` and
`--timeout-ms`. Every artifact download first writes a temp file in the same directory and
validates blob metadata, offsets, base64, total length, and SHA-256 chunk by chunk, renaming only
after everything passes; an existing output is refused by default and replaced only with an
explicit `--force`. Expiry, rejection, out-of-order chunks, hash errors, and interruptions never
leave a partial file under the final output name.

## Connection Boundary

`--ws-uri` may contain VM Service authentication material:

- take it only from trusted launcher output or the current debug session;
- never write it into scripts, logs, snapshots, or anything you commit;
- CLI errors report only the error category, never echoing the full URI.

The launcher first writes a provisional record via atomic replace, then fills in the URI once it
receives `app.debugPort`; only after the CLI connects and reads `ext.patchbay.identity` are
`appInstanceId` and `isolateId` filled in. A complete record binds the session schema,
`applicationId`, `appInstanceId`, `isolateId`, launcher PID, `wsUri`, build mode, creation time,
worktree, and device ID. Records live in the current user's system temp directory by default, and
`PATCHBAY_SESSION_DIR` can override that. The launcher still echoes `app.log`, `app.progress`, and
stderr in human-readable form, but uniformly replaces any http/ws URI within them; `app.debugPort`
only prints "session discovered" and never echoes the machine event payload.

A live PID only means the launcher may still be running — it does not prove the app instance is
still the same one. Any of the following deletes the record and returns a stable session error: a
dead PID, an unreachable URI, or a schema/identity mismatch. When a hot restart produces
`app.debugPort` again, the launcher atomically resets the identity it had filled in and the CLI
must re-measure it; an explicit `--ws-uri` runs the same schema/isolate/appInstance identity check.
The launcher deletes the records it owns on exit. On POSIX the directory and files are tightened to
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
For the stable commands, passthrough boundaries, and exit conditions of the three trees and
actions, see
[`../patchbay_flutter/docs/ui-inspection-and-actions.md`](../patchbay_flutter/docs/ui-inspection-and-actions.md)
(currently in Chinese).
