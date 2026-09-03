import 'dart:async';

import 'package:patchbay_flutter/patchbay_flutter_host.dart';
import 'package:patchbay_transport/patchbay_transport.dart';

/// Serves the **same** host dispatch over the optional direct HTTP transport.
///
/// Why this exists: VM Service and direct must answer identically for every
/// shared capability. Wiring direct to a second, hand-written handler set would
/// make that impossible to verify — the two paths would drift by construction.
/// So this bridges straight onto the transport-neutral dispatch seam
/// (`dispatchCatalog` / `dispatchSnapshot` / `dispatchInvoke`), which is the
/// same code VM Service registration calls. Identity is rebuilt from the host's
/// own applicationId / appInstanceId because the direct plane carries its own
/// typed identity envelope.
///
/// It stays **off unless asked**: the direct transport binds a real socket, and
/// an app that opens one by default would expose its debug plane to anything
/// that can reach the device. Start it with
/// `flutter run --dart-define=patchbay.direct=1`.
final class ExampleDirectTransport {
  ExampleDirectTransport({required this.host});

  final PatchbayFlutterServiceHost host;

  PatchbayDirectHost? _direct;
  PatchbayDirectSession? _session;

  /// Whether the consumer asked for the direct plane at build time.
  ///
  /// A compile-time define, not a runtime flag: a switch a running app could
  /// flip is a switch an attacker could flip.
  static const bool requested = bool.fromEnvironment('patchbay.direct');

  PatchbayDirectSession? get session => _session;

  /// Binds loopback only. Reaching it from a workstation needs an explicit
  /// `adb forward`, which keeps the exposure decision with the operator
  /// instead of the app.
  Future<PatchbayDirectSession?> start({int port = 0}) async {
    if (!requested || _direct != null) return _session;
    final PatchbayDirectHost direct = PatchbayDirectHost(
      handlers: PatchbayDirectHandlers(
        identity: () async => PatchbayDirectIdentity(
          schemaVersion: PatchbayServiceHost.schemaVersion,
          applicationId: host.applicationId,
          appInstanceId: host.appInstanceId,
          features: <String>[
            for (final PatchbayFeature feature in host.features) feature.name,
          ],
        ),
        catalog: host.dispatchCatalog,
        snapshot: ([Map<String, Object?>? request]) =>
            host.dispatchSnapshot(request),
        invokeWithContext:
            (
              String command,
              Map<String, Object?> arguments,
              String requestId, {
              String? ownerToken,
              Duration? deadline,
            }) {
              final PatchbayHostInvocationHandle handle = host
                  .dispatchInvokeHandle(
                    command,
                    arguments,
                    requestId,
                    ownerToken: ownerToken,
                    deadline: deadline,
                  );
              return PatchbayDirectInvocationHandle(
                response: handle.response,
                lifecycle: handle.lifecycle,
              );
            },
        cancelInvocation:
            (
              String command,
              String requestId,
              String ownerToken, {
              required String reason,
            }) => host
                .cancelInvocation(
                  command: command,
                  requestId: requestId,
                  ownerToken: ownerToken,
                  reason: PatchbayInvocationCancellationReason.values.byName(
                    reason,
                  ),
                )
                .then(
                  (PatchbayInvocationCancellationResult result) =>
                      result.toJson(),
                ),
      ),
      config: PatchbayDirectHostConfig(port: port),
    );
    _direct = direct;
    _session = await direct.start();
    return _session;
  }

  Future<void> stop() async {
    final PatchbayDirectHost? direct = _direct;
    _direct = null;
    _session = null;
    await direct?.stop();
  }
}
