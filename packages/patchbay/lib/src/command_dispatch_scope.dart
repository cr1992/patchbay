import 'dart:async';

import 'command_descriptor.dart';

final Object _patchbayCommandDispatchIdentityKey = Object();

/// Immutable identity of the exact registration currently executing.
///
/// This is internal dispatch plumbing. The registry is intentionally an
/// identity token rather than a command-name lookup: a handler must not be
/// able to select another registered command's contract with a string.
final class PatchbayCommandDispatchIdentity {
  const PatchbayCommandDispatchIdentity({
    required this.registry,
    required this.descriptor,
  });

  final Object registry;
  final PatchbayCommandDescriptor descriptor;
}

PatchbayCommandDispatchIdentity? get patchbayCommandDispatchIdentity =>
    Zone.current[_patchbayCommandDispatchIdentityKey]
        as PatchbayCommandDispatchIdentity?;

Future<T> runInPatchbayCommandDispatchScope<T>({
  required Object registry,
  required PatchbayCommandDescriptor descriptor,
  required FutureOr<T> Function() body,
}) => runZoned<Future<T>>(
  () async => await body(),
  zoneValues: <Object?, Object?>{
    _patchbayCommandDispatchIdentityKey: PatchbayCommandDispatchIdentity(
      registry: registry,
      descriptor: descriptor,
    ),
  },
);
