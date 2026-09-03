# Install the Patchbay Skill

This installs reusable agent guidance only. It does not add the Patchbay package to an App, install
the Patchbay CLI, start a device, or enable a host.

## Prove it works first

Before installing this Skill for a consumer App, or if you just need to confirm the CLI and a
Patchbay host actually talk to each other, run the repository's own
[10-minute quick path](../../docs/quickstart.md). It uses the checked-in example App and a CLI
built from source, needs no App integration work, and ends with a real `snapshot`, a safe
`ui perform` write, and a `capture`. Treat a clean run of it as the baseline before layering the
steps below onto a real consumer App.

## Version contract

The Skill is released with the Patchbay repository tag rather than on an independent version line.
Start with the same Patchbay tag for the App dependency, CLI, and Skill. Any supported mixed-version
combination must be justified by the repository compatibility matrix, not by the Skill text.

For unreleased development, install from the checked-out `dev/<SemVer>` branch and treat that checkout
as one candidate. Do not combine a development Skill with an unrelated installed CLI and report the
result as release evidence.

## Codex personal installation

From a Patchbay checkout, link the complete Skill folder into the Codex Skill root:

```console
$ mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills"
$ ln -s "$PWD/skills/use-patchbay" "${CODEX_HOME:-$HOME/.codex}/skills/use-patchbay"
```

The link command fails if the target already exists. Inspect the existing installation and update it
intentionally; do not force-overwrite an unknown Skill. Start a new Codex task after installation so
the available-Skills catalog is refreshed.

The installed directory must contain both `SKILL.md` and this file. Invoke `$use-patchbay` explicitly
for the first smoke test; normal discovery can remain enabled afterward.

## App and CLI prerequisites

For a tagged release, use the repository [Quick Start](../../README.md#quick-start) to add the
matching hosted Flutter dependency, install the matching release CLI, and register the host at the
App composition root. Chinese readers can start from the
[中文快速开始](../../README.zh-CN.md#快速开始).

For an unreleased `dev/<SemVer>` candidate, do not use the stable hosted dependency or release CLI
from that Quick Start. Build the CLI from the same Patchbay checkout root and keep that absolute
build directory on `PATH` for the task:

```console
$ dart run packages/patchbay_cli/tool/build_cli.dart
$ export PATH="$PWD/packages/patchbay_cli/build:$PATH"
```

Point the consumer App at packages from that checkout as well. This example assumes the consumer
and a checkout named `patchbay` are sibling directories:

```yaml
dependencies:
  patchbay_flutter:
    path: ../patchbay/packages/patchbay_flutter

dependency_overrides:
  patchbay:
    path: ../patchbay/packages/patchbay
```

Adjust both relative paths together when the checkout has a different location. Do not mix a local
`patchbay_flutter` with hosted `patchbay`; the override is what keeps the host and protocol on the
same candidate. The full [usage guide](../../docs/guide.md) is a reference layer, not required
reading before the first identity/catalog/snapshot check.

Keep the host behind the consumer's debug/profile compile-time branch. The minimal integration should
open read-only diagnosis first; domain commands, captures, logs, navigation, and write actions remain
explicit capabilities with their own gates.
