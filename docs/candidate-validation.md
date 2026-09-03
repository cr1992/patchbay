# Validate a release candidate

Published Patchbay packages correctly depend on one another through hosted version constraints.
Before a candidate is published, overriding only `patchbay_flutter` with a Git dependency mixes Git
and hosted sources and can make version solving fail. Candidate validation therefore pins all four
packages to one repository and one immutable commit.

## 1. Make all four packages reachable

Keep your app's existing `patchbay_flutter` dependency. For the validation run, also make the CLI
part of the consumer's dependency graph so that `patchbay_transport` is resolved from the same
candidate:

```yaml
dev_dependencies:
  patchbay_cli: any # Candidate validation only.
```

A pure Dart consumer can keep its existing `patchbay` dependency, but validating the complete
four-package release candidate requires a Flutter consumer.

## 2. Generate the temporary overrides

From the Patchbay candidate checkout, use the repository URL that is reachable from the consumer
and the full 40-character candidate commit SHA:

```console
$ dart run tool/repo_tasks.dart candidate-consumer \
    --repository '<git-url>' \
    --commit '<40-character-commit-sha>' \
    --output /path/to/consumer/pubspec_overrides.yaml
```

Do not use `dev/0.6.0`, another moving branch, or a short SHA. Do not commit the generated
`pubspec_overrides.yaml`; it is a candidate-only overlay, not the published dependency shape.

## 3. Resolve and verify

Run dependency resolution in the consumer, then ask the same tool to verify the lock file:

```console
$ cd /path/to/consumer
$ flutter pub get
$ cd /path/to/patchbay
$ dart run tool/repo_tasks.dart candidate-consumer \
    --repository '<git-url>' \
    --commit '<40-character-commit-sha>' \
    --verify-lock /path/to/consumer/pubspec.lock
```

The check fails unless all four packages use the expected Git URL, full `ref`, resolved commit, and
monorepo package path. A green lock check proves dependency provenance only; still run the
consumer's analyze, tests, build, and real-device acceptance against that same commit.

## 4. Remove the candidate overlay

After validation, delete `pubspec_overrides.yaml`, remove the temporary `patchbay_cli` dev
dependency if the consumer does not normally use it, and run `flutter pub get` again. For a released
version, use the normal hosted constraints instead of retaining Git overrides.
