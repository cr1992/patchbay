# Patchbay

<p align="center">
  <img src="docs/assets/patchbay-hero.svg" width="100%" alt="Patchbay: connect safely to a running Flutter app from your terminal">
</p>

<p align="center">
  <strong>Talk to your running Flutter app the way adb talks to a device.</strong>
</p>

<p align="center">
  English | <a href="https://github.com/cr1992/patchbay/blob/main/README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="#what-it-solves">Use cases</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#what-you-can-do">Capabilities</a> ·
  <a href="#architecture-and-packages">Architecture</a> ·
  <a href="docs/guide.md">Usage guide</a> ·
  <a href="docs/design.md">Design</a>
</p>

Patchbay is a typed control channel reaching into the Flutter runtime: connect to a running app
from your terminal, read state with its fact source attached, invoke domain commands, drive
widgets by stable ID, and pull redacted logs and screenshots.

adb looks at a device from outside the system; Patchbay looks at the runtime from inside the app.
On iOS in particular, it fills in the in-app debugging surface that system tooling cannot provide.

> **Project status:** `v0.4.1`, published on pub.dev; requires Dart `>=3.11.0`, and Flutter
> `>=3.38.0` for the Flutter UI capabilities. The control plane is enabled only in debug /
> profile; the packages can take part in a release compile, but the consumer must keep the host
> and adapters unreachable through compile-time branching at the composition root.

## What It Solves

| Use Patchbay for | Keep using adb / xcrun for |
|---|---|
| Reading typed state from inside the app | Installing, uninstalling, and launching apps |
| Invoking domain commands the app deliberately exposes | Running a system shell |
| Driving Flutter Semantics or stable UI IDs | Installing, launching, and inspecting other apps |
| Orchestrating expected system permission dialogs through an explicit external driver | General system UI automation or coordinate-driven dialog handling |
| Fetching redacted app-side logs and Flutter screenshots | Capturing the full physical screen or the internals of a native `PlatformView` |

Patchbay is not an adb replacement, nor a coordinate-driven black-box test framework; the complete
debugging toolchain is the two of them used together.

## Quick Start

The shortest path below runs over VM Service. For the full treatment of gates, domain commands,
session discovery, and direct HTTP integration, see the [usage guide](docs/guide.md)
(currently in Chinese).

### 1. Add the Flutter dependency

Use the hosted package for normal integration:

```yaml
dependencies:
  patchbay_flutter: ^0.4.1
```

`patchbay_flutter` re-exports the core API; for pure Dart integration use `packages/patchbay`
instead.

### 2. Install the CLI

The following installs the native AOT GitHub Release artifact on macOS arm64. See the
[installation guide](docs/guide.md#cli) for other platforms and checksum verification:

```console
$ mkdir -p ~/.local/bin
$ curl -fL https://github.com/cr1992/patchbay/releases/download/patchbay-v0.4.1/patchbay-0.4.1-macos-arm64 \
    -o ~/.local/bin/patchbay
$ chmod +x ~/.local/bin/patchbay
$ patchbay --help
```

Make sure `~/.local/bin` is on `PATH`. `dart pub global activate patchbay_cli` remains a compatible
alternative, but it installs an app snapshot loaded by the Dart runtime, not a standalone native
AOT executable; do not use it to measure native AOT startup.

When that compatibility form is required, pin it to the same package version:

```console
$ dart pub global activate patchbay_cli 0.4.1
```

### 3. Register at the composition root

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

void main() {
  if (!kReleaseMode) {
    final gates = PatchbayGateEvaluator(
      baseGate: () => const PatchbayGateDecision.allow(),
      consumerGate: (id) => PatchbayGateDecision.reject(
        code: 'unknownConsumerGate',
        notice: 'No consumer gate named $id.',
      ),
    );

    PatchbayFlutterServiceHost(
      applicationId: 'com.example.app',
      bridge: PatchbayFlutterBridge(gates: gates),
    ).register();
  }

  runApp(const MyApp());
}
```

This minimal integration already gives you identity, catalog, an empty snapshot, read-only
Semantics observation, and `ui.wait`. Semantics actions are rejected by default; domain commands,
capture, logs, and navigation each require the app to inject the corresponding capability
explicitly.

When you need a stable text target, replace the existing Key with a `PatchbayKey`. It is a
`GlobalKey`, so it must be cached like any ordinary `GlobalKey` and never reconstructed on every
`build()`:

```dart
late final PatchbayKey phoneKey = PatchbayKey.text('login.phone');

@override
Widget build(BuildContext context) => TextField(
  key: phoneKey,
  controller: phoneController,
);
```

### 4. Connect to the running app

Run the app and copy the VM Service URI that `flutter run` prints. Patchbay accepts both `http(s)`
and `ws(s)` URIs:

```console
$ flutter run
$ patchbay --ws-uri '<VM Service URI>' identity
$ patchbay --ws-uri '<VM Service URI>' catalog
$ patchbay --ws-uri '<VM Service URI>' --json snapshot
```

A VM Service URI usually carries authentication material — keep it out of scripts, logs, and
anything you commit. Once the launcher is wired up you can drop `--ws-uri` entirely; see
[automatic session discovery](docs/guide.md#6-会话自动发现可选). With several devices connected at
once, use `patchbay sessions list` to see the available sessions and `patchbay session use
<session-id>` to pin one, so later commands no longer need `--session`; see
[session selection](docs/guide.md#会话选择).

UI targets in the catalog come with their current `generation`. Write operations that declare a
caller-side generation fence (text input, for example) must carry that value, so a late command
cannot land on a same-named widget that has since remounted; `ui tap` may omit the generation, as
the host pins the generation for that operation once it has resolved the identifier:

```console
$ patchbay --ws-uri '<VM Service URI>' ui text set login.phone <generation> '13800000000'
```

## What You Can Do

| Capability | What Patchbay provides |
|---|---|
| **State** | Typed `snapshot`, every value carrying its fact source (app-recorded / command echo / device-reported / UI-observed); select one field by dot path, or have the app wait until a field meets a condition |
| **Domain commands** | Consumer-registered domain commands call existing controllers directly; long flows run as jobs (admission / events / terminal state) |
| **UI operations** | Text input, Semantics actions, three diagnostic trees, capture, and conditional waits — only against explicitly opened targets |
| **Logs** | query / tail / export, redacted uniformly at every exit |
| **Navigation** | Jump by stable destination ID, without exposing arbitrary route strings |
| **Continuous execution** | `repl` runs typed commands line by line over a single connection, each line with its own exit code |
| **Help** | Generated from command declarations; browse with `patchbay help <topic>` |

```console
$ patchbay identity
$ patchbay --json snapshot
$ patchbay --wait exec example.job.run
$ patchbay ui semantics tree
$ patchbay ui tap login.submit
$ patchbay --output screen.png capture root
$ patchbay logs tail
$ patchbay repl < commands.txt
```

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
| `patchbay ui focus-tree` | client CLI declaration | — |
| `patchbay ui gesture drag <identifier> <generation> --start <json> --gesture-path <json> [--duration-ms <ms>]` | protocol descriptor | `ui.gesture.drag` |
| `patchbay ui gesture fling <identifier> <generation> --start <json> --velocity <json> [--duration-ms <ms>]` | protocol descriptor | `ui.gesture.fling` |
| `patchbay ui gesture press-hold <identifier> <generation> --start <json> [--duration-ms <ms>]` | protocol descriptor | `ui.gesture.pressHold` |
| `patchbay ui inspect off` | protocol descriptor | `ui.inspect.select` |
| `patchbay ui inspect on [--ttl-ms <ms>]` | protocol descriptor | `ui.inspect.select` |
| `patchbay ui inspect status` | protocol descriptor | `ui.inspect.status` |
| `patchbay ui keep-awake off` | protocol descriptor | `ui.keepAwake.set` |
| `patchbay ui keep-awake on [--lease-ms <ms>]` | protocol descriptor | `ui.keepAwake.set` |
| `patchbay ui keep-awake status` | protocol descriptor | `ui.keepAwake.status` |
| `patchbay ui render-tree` | client CLI declaration | — |
| `patchbay ui semantics action <node-id> <generation> <action> [text]` | protocol descriptor | `ui.semantics.action` |
| `patchbay ui semantics tree` | protocol descriptor | `ui.semantics.tree` |
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
| `patchbay ui widget-tree` | client CLI declaration | — |
<!-- PATCHBAY_COMMAND_REFERENCE:END -->

## Why Patchbay

Ordinary external automation sees pixels, copy, and coordinates; Patchbay sees the semantics and
facts the app deliberately exposes:

- **Trustworthy** — state values carry their fact source, and admission, execution, and
  device-level completion are never conflated;
- **Controlled** — every command passes the base gate and its declared gate, reaching only the
  capabilities the app has explicitly opened;
- **Stable** — UI targets use stable IDs and generation fencing, rather than coordinates, tree
  indices, or volatile copy;
- **Strippable** — consumers use compile-time branching to make the host and adapters unreachable
  in release, leaving no runtime switch to turn them back on.

None of this is a guarantee the transport makes on the app's behalf. Domain completion, privacy
redaction, release artifact scanning, and platform behavior remain the consumer's responsibility,
judged against its own controllers, build chain, and real-device results. The reasoning is in
[the six design positions](docs/design.md#六条设计立场) (currently in Chinese).

## Architecture and Packages

<p align="center">
  <img src="docs/assets/patchbay-architecture.svg" width="100%" alt="Patchbay architecture: the CLI enters the gated control plane inside the app over VM Service or direct HTTP">
</p>

The CLI only ever faces one unified protocol. VM Service is the default main channel; direct HTTP
is an optional channel you turn on explicitly. Inside the app, every operation passes the gates
first and is then handed to the Flutter bridge, a domain adapter, or the artifact service; the real
state machines, router, device SDKs, and privacy policy still belong to the app itself.

| Package | Depends on | Responsibility |
|---|---|---|
| [`patchbay`](packages/patchbay) | Pure Dart | Protocol, command declarations, envelopes, fact sources, gates, jobs, blobs |
| [`patchbay_cli`](packages/patchbay_cli) | Pure Dart | CLI, session discovery, VM Service / direct clients, output and exit codes |
| [`patchbay_flutter`](packages/patchbay_flutter) | Flutter | Key / Semantics operations, capture, navigation, and waits |
| [`patchbay_transport`](packages/patchbay_transport) | Pure Dart | Optional direct HTTP; off by default, must be started explicitly |

Domain DTOs, device SDKs, routing, and domain vocabulary all stay in the consumer's adapter — none
of it enters these four general-purpose packages.

## Glossary

| Term used in the docs | Meaning |
|---|---|
| consumer | The app using Patchbay, or its adapter layer |
| descriptor | A structured description of a command's name, parameters, gates, side effects, and fact sources |
| gate | The admission check the app runs before every operation |
| generation | An anti-misfire version number that changes each time a UI target remounts |
| job | An asynchronous domain operation expressed through events and a typed terminal state |

## Documentation

Long-form documents under `docs/` are currently in Chinese only.

- **[Usage guide](docs/guide.md)** — installation, app integration, CLI manual, exit codes, and boundaries (in Chinese)
- **[Design](docs/design.md)** — architecture, the six design positions, and transport selection (in Chinese)
- **[Core package](packages/patchbay/README.md)** — protocol, envelopes, gates, jobs, and blobs
- **[Flutter package](packages/patchbay_flutter/README.md)** — UI observation, operations, navigation, and capture
- **[CLI package](packages/patchbay_cli/README.md)** — the full command set and connection safety
- **[Direct transport](packages/patchbay_transport/README.md)** — HTTP protocol and LAN risks
- **[Changelog](CHANGELOG.md)** — unreleased and released changes to the API, protocol, and security behavior

## License

[MIT](LICENSE)
