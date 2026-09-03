# 10-Minute Quick Path

This is the shortest way to prove to yourself — or to an agent with zero prior context — that
Patchbay works, using only the app and CLI already checked into this repository. No app
integration work, no writing Dart. If you already have a Patchbay-enabled app of your own, skip
this and use the [README Quick Start](../README.md#quick-start) instead; this page exists to get
a first result in minutes, not to teach integration.

Six steps: install, `identity`, `catalog`, `snapshot`, one safe write through `ui perform`, and a
`capture`. Every command below is copy-pasteable and was checked against this checkout's own
`patchbay help` output. Each step says what you should see and which `error.code` to look for if
it does not work that way.

**Prerequisites:** a working Dart and Flutter toolchain on `PATH` (Dart `>=3.12.0`, Flutter
`>=3.44.0`) and a Flutter target you can normally `flutter run` against — simulator, emulator,
physical device, or desktop all work, since Patchbay only needs the Dart VM Service URI that
`flutter run` prints, not a specific platform. A clean checkout of this repository. The 10-minute
budget assumes that toolchain already works and `flutter run`'s first build is not unusually slow.

If any step below fails to connect at all, run `patchbay doctor` first — it checks session,
connection, catalog and app lifecycle in one pass and reports which one broke; see
[Doctor](guide.md#体检doctor) for how to read it. The full syntax for every command mentioned here
is in `patchbay help <command>`; the full error code catalog is in
[Exit codes](guide.md#退出码).

## 1. Install

From the repository root, this checkout is not a tagged release, so build the CLI from source
once and fetch dependencies:

```console
$ dart pub get
$ (cd packages/patchbay_flutter/example && flutter pub get)
$ dart run packages/patchbay_cli/tool/build_cli.dart
$ export PATH="$PWD/packages/patchbay_cli/build:$PATH"
```

**You'll see:** `dart`/`flutter pub get` resolving dependencies for the two packages, then
`Built .../build/patchbay (N.N MiB)` from the build script. `patchbay --help` should now print the
command group list from any directory.

Now run the bundled example app and copy the VM Service URI it prints:

```console
$ cd packages/patchbay_flutter/example
$ flutter run
```

**You'll see:** Flutter's normal build/launch output, ending with a line like
`A Dart VM Service on <device> is available at: http://127.0.0.1:<port>/<token>=/` and a running
app showing a counter and a "Debug note" text field. Copy that URI — it changes on every
`flutter run`, and it carries authentication material, so keep it out of scripts, shell history
files, and anything you commit.

**If this doesn't work:** these are Flutter-level failures (no device found, build error), not
Patchbay's — resolve them with ordinary `flutter doctor` / `flutter run` troubleshooting before
continuing.

## 2. Say hello: `identity`

```console
$ export WS_URI='<the VM Service URI you just copied>'
$ patchbay --ws-uri "$WS_URI" identity
```

(`export`ing it once avoids retyping the URI in every command below; nothing about that variable
is Patchbay-specific.)

**You'll see:** the runtime identity handshake — `applicationId` (`dev.patchbay.example` for this
example), `appInstanceId`, `isolateId`, `schemaVersion`, `serverVersion`, and the `features` this
host declares. Exit code `0` and no `error` field means the minimal read-only path is already
working.

**If it fails:** exit `3` means no valid connection — the most common cause at this step is a
stale URI (each `flutter run` mints a new one); re-copy it. Exit `4` means a schema/identity
mismatch. Either way, `patchbay doctor` will name the broken layer.

## 3. Discover: `catalog`

```console
$ patchbay --ws-uri "$WS_URI" --json catalog
```

**You'll see:** the commands and UI targets this running app actually registers — this is the
only source of truth for what is callable; a target's entry carries an `id` and a `generation`
you will need in step 5. The example's target list includes `example.note` (a text field) and a
semantics identifier `example.counter.increment` (a button); nothing else in this guide, the
README, or the Skill is a substitute for reading this output yourself. If the plain output is too
long to read, add `--view brief` to keep the decision facts and drop the bulky field (it is always
named in `localView.omitted`, never silently missing).

**If it fails:** same connection-class codes as step 2. A `patchbay describe <command>` on any
name you see here shows its live parameters and gates without invoking it.

## 4. Read: `snapshot`

```console
$ patchbay --ws-uri "$WS_URI" --json snapshot
```

**You'll see:** the app's typed state tree, with every value tagged by its fact source
(app-recorded / command echo / device-reported / UI-observed) — not a plain value dump. Narrow it
with `--path <dot.path>` (for example `--path counter`) once you know the field you want; use
`snapshot wait <dot.path> --until exists|absent|equals [<json>]` to have the app wait for a
condition instead of polling yourself.

**If it fails:** the same connection-class codes apply; a bad `--path` fails closed rather than
guessing at a partial match.

## 5. Make a safe write: `ui perform`

`ui perform` is the one canonical entry point for every UI write in this version; it always
takes an explicit selector (`target:`, `semantics:`, or `node:`) and the `generation` you read
from `catalog` in step 3 — a write against a stale generation is rejected, not silently retried.

Write into the registered text target:

```console
$ patchbay --ws-uri "$WS_URI" ui perform enter-text target:example.note <generation> "Hello from Patchbay"
```

**You'll see:** the app's "Debug note" field now shows that text, and the CLI exits `0`. Substitute
`<generation>` with the value you read for `id: "example.note"` in step 3.

Or dispatch a real accessibility tap on the counter button:

```console
$ patchbay --ws-uri "$WS_URI" ui perform tap semantics:example.counter.increment <generation> --via semantics
```

**You'll see:** the on-screen counter increments by one.

**If it fails:** `uiTargetNotFound` / `uiSemanticsIdentifierNotFound` means that selector is not
currently registered or mounted — re-read `catalog`. `uiGenerationStale` /
`uiSemanticsGenerationStale` means the target remounted since you read its generation — the reply
carries `currentGeneration`; read it again and resend, the CLI never retries this for you.
`uiSemanticsIdentifierAmbiguous` means more than one mounted node currently matches. A gate
rejection (`baseGateRejected`, `consumerGateRejected`, or a consumer-declared code such as
`unknownConsumerGate`) means the app itself declined the write; this bundled example ships with
its one write gate open, so you should not see this here — it is what to expect against an app
that has not opened that capability.

## 6. Capture

```console
$ patchbay --ws-uri "$WS_URI" --output note.png capture root
```

**You'll see:** exit `0` and a PNG written to `note.png` — the Flutter root repaint boundary at
the moment of the call, including the text and counter value from step 5.

**If it fails:** if `note.png` already exists you get a `usageError` (exit `64`) telling you to
add `--force` or pick a new path; connection-class failures are the same codes as the earlier
steps.

## Where to go next

You have now run the whole read → write → capture path this repository ships end to end. From
here:

- Wiring these same capabilities into your own app: the
  [README Quick Start](../README.md#quick-start) and [App integration](guide.md#app-接入).
- The complete command set, every exit code, and every UI write entry point (not just the two used
  above): [Common commands](guide.md#常用命令) and [Exit codes](guide.md#退出码).
- Connecting without copying a URI by hand every time, and reusing one connection across several
  commands: [Automatic session discovery](guide.md#6-会话自动发现可选), [Session
  selection](guide.md#会话选择), and [Choose a workflow](guide.md#先选工作流).
- An AI agent driving Patchbay task by task, with read-only-first safety rules: the
  [Agent Skill](../skills/use-patchbay/SKILL.md).

The [usage guide](guide.md) is the complete reference and is currently Chinese-only; this page is
the English entry point into it, not a replacement for it.
