# Patchbay

<p align="center">
  <img src="docs/assets/patchbay-hero.svg" width="100%" alt="Patchbay: connect safely to a running Flutter app from your terminal">
</p>

<p align="center">
  <strong>Talk to your running Flutter app the way adb talks to a device.</strong>
</p>

<p align="center">
  English | <a href="README.zh-CN.md">简体中文</a>
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

> **Project status:** `v0.2.1`, consumed from source; requires Dart `>=3.11.0`, and Flutter
> `>=3.38.0` for the Flutter UI capabilities. The control plane is enabled only in debug /
> profile; the packages can take part in a release compile, but the consumer must keep the host
> and adapters unreachable through compile-time branching at the composition root.

## What It Solves

| Use Patchbay for | Keep using adb / xcrun for |
|---|---|
| Reading typed state from inside the app | Installing, uninstalling, and launching apps |
| Invoking domain commands the app deliberately exposes | Running a system shell |
| Driving Flutter Semantics or stable UI IDs | Handling system permission dialogs and other apps |
| Fetching redacted app-side logs and Flutter screenshots | Capturing the full physical screen or the internals of a native `PlatformView` |

Patchbay is not an adb replacement, nor a coordinate-driven black-box test framework; the complete
debugging toolchain is the two of them used together.

## Quick Start

The shortest path below runs over VM Service. For the full treatment of gates, domain commands,
session discovery, and direct HTTP integration, see the [usage guide](docs/guide.md)
(currently in Chinese).

### 1. Add the Flutter dependency

These packages are not published to pub.dev yet — reference them from Git, pinned to a tag:

```yaml
dependencies:
  patchbay_flutter:
    git:
      url: https://github.com/cr1992/patchbay.git
      ref: patchbay-v0.2.1
      path: packages/patchbay_flutter
```

`patchbay_flutter` re-exports the core API; for pure Dart integration use `packages/patchbay`
instead.

### 2. Install the CLI

```console
$ dart pub global activate --source git https://github.com/cr1992/patchbay.git \
    --git-ref patchbay-v0.2.1 --git-path packages/patchbay_cli
$ patchbay --help
```

If the global command is not on your `PATH`, add the pub cache `bin` directory to `PATH` as Dart
instructs.

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
[automatic session discovery](docs/guide.md#5-会话自动发现可选). With several devices connected at
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
$ patchbay --wait exec pairing.ble.pair
$ patchbay ui semantics tree
$ patchbay ui tap login.submit
$ patchbay --output screen.png capture root
$ patchbay logs tail
$ patchbay repl < commands.txt
```

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
