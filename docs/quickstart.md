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
budget assumes that toolchain already works, `flutter run`'s first build is not unusually slow, and
the example's mobile platform directory already exists or you take the non-interactive path in
step 1 below — generating that directory from scratch (see step 1) is a one-time cost on top of
the budget.

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

**The bundled example ships with no platform directory.** This is a four-package repository, not a
maintained Flutter app project — `example/.gitignore` excludes `ios/`, `android/`, and the other
platform folders on purpose, so a simulator, emulator, or physical device target does not exist yet
in a fresh checkout. Generate the one you need, once, from inside
`packages/patchbay_flutter/example`:

```console
$ (cd packages/patchbay_flutter/example && flutter create --platforms=ios .)   # or --platforms=android
```

`flutter create` runs its own `pub get` outside the checked-in lockfile, which can bump a transitive
dependency in `pubspec.lock` and add a template `test/widget_test.dart` that does not match this
example's own `main.dart`. Both are side effects of the generator, not changes you meant to make —
undo them before committing anything from this checkout:

```console
$ git checkout -- packages/patchbay_flutter/example/pubspec.lock
$ rm -f packages/patchbay_flutter/example/test/widget_test.dart
```

(The non-interactive path below performs the same generation for you and warns you on stderr if it
touches `pubspec.lock`, so you can skip doing this by hand if you use it.)

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

**If this doesn't work:** an error like `No application found for TargetPlatform.ios. Is your
project missing an ios/Runner/Info.plist?` (or the Android equivalent) means the platform directory
above is still missing — go back and generate it. Anything else at this step is an ordinary
Flutter-level failure (no device found, build error), not Patchbay's — resolve it with `flutter
doctor` / `flutter run` troubleshooting before continuing.

### Non-interactive path (scripts and agents)

An agent or a script cannot drive the interactive `flutter run` above: the process stays in the
foreground and never returns, and copying a URI out of its stdout by hand does not scale. Source
the repository's own session helper instead — it also generates the platform directory for you, so
it replaces both this step and the one above:

```console
$ source tool/example_session.sh
$ example_session_start <device-id>
```

`<device-id>` is whatever `flutter devices` lists for your target (an adb serial for Android, a
`xcrun simctl list devices` UDID for an iOS Simulator); omit it to use the first online adb device.
On success it prints `[session] 会话已就绪：<id>` and exports `PATCHBAY_SESSION_ID` (and
`PATCHBAY_SESSION_DIR`) — the URI itself is never printed and never touches shell history. Run the
commands in steps 2 through 6 through its `example_session_cli` wrapper instead of a bare
`patchbay --ws-uri` call, for example `example_session_cli --json catalog`; it forwards to the same
`--session` mechanism [Automatic session discovery](guide.md#6-会话自动发现可选) describes. Call
`example_session_stop` when you're done to end the app process and clean up the session record.

The helper's own status lines are written in Chinese and all start with `[session]`; they are
progress and warnings from the helper, not Patchbay responses, and none of them carries an
`error.code`.

The helper locates this checkout on its own whether you source it from bash or zsh. If it stops
with `[session] 无法定位仓库根` instead, set `PATCHBAY_REPO_ROOT` to the root directory of this
checkout and source it again — an explicit `PATCHBAY_REPO_ROOT` always wins over auto-detection.

**If your runner starts a fresh shell per command** (most agent hosts do), the exported
`PATCHBAY_SESSION_ID` does not survive to the next command. Keep the id from the
`[session] 会话已就绪：<id>` line, then in each later shell `source tool/example_session.sh` and
`export PATCHBAY_SESSION_ID=<id>` before calling `example_session_cli`; `PATCHBAY_SESSION_DIR`
re-derives itself from the checkout, so you only have to carry the id.

## 2. Say hello: `identity`

```console
$ export WS_URI='<the VM Service URI you just copied>'
$ patchbay --ws-uri "$WS_URI" identity
```

(`export`ing it once avoids retyping the URI in every command below; nothing about that variable
is Patchbay-specific.)

**You'll see:** one human-readable line naming the app and the instance it handed you — for this
example `dev.patchbay.example instance=<id>`. That is the whole point of this step: exit code `0`
and no `error` means the minimal read-only path is already working. Add `--json` (as every step
below does) when you want the full handshake instead — `applicationId`, `appInstanceId`,
`isolateId`, `schemaVersion`, `serverVersion` and the `features` this host declares.

**If it fails:** exit `3` means no valid connection — the most common cause at this step is a
stale URI (each `flutter run` mints a new one); re-copy it. Exit `4` means a schema/identity
mismatch. Either way, `patchbay doctor` will name the broken layer.

## 3. Discover: `catalog`

```console
$ patchbay --ws-uri "$WS_URI" --json catalog
```

**You'll see:** the commands and UI targets this running app actually registers — this is the
only source of truth for what is callable; each entry under `uiTargets` carries an `id` and a
`generation` you will need in step 5. The example registers `example.note` (a text field) as a
target. Accessibility nodes such as the counter button (`example.counter.increment`) are not
registered targets and do not appear here — step 5 reads them from `ui semantics tree`. Nothing
else in this guide, the README, or the Skill is a substitute for reading this output yourself. If the plain output is too
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
takes an explicit selector (`target:`, `semantics:`, or `node:`) and the `generation` you
observed before writing — a write against a stale generation is rejected, not silently retried.
The two identity domains keep separate counters: a `target:` generation comes from `catalog`'s
`uiTargets` (step 3, or `patchbay ui targets`); a `semantics:` or `node:` generation comes from
`ui semantics tree`, never from `catalog`.

Write into the registered text target:

```console
$ patchbay --ws-uri "$WS_URI" ui perform enter-text target:example.note <generation> "Hello from Patchbay"
```

**You'll see:** the app's "Debug note" field now shows that text, and the CLI exits `0`. Substitute
`<generation>` with the value you read for `id: "example.note"` in step 3.

Or dispatch a real accessibility tap on the counter button. First read the semantics tree and
find the node whose `identifier` is `example.counter.increment`; its `generation` is the value
to pass:

```console
$ patchbay --ws-uri "$WS_URI" --json --view brief ui semantics tree
$ patchbay --ws-uri "$WS_URI" ui perform tap semantics:example.counter.increment <generation> --via semantics
```

**You'll see:** the on-screen counter increments by one. (`--view brief` keeps the node list
readable; the full tree is one `--view full` away.)

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
