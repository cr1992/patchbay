import 'package:patchbay_transport/patchbay_transport.dart';

import 'client.dart';

/// Adapts the explicit direct HTTP transport to the same command client used
/// by the VM Service path. Flutter SDK diagnostic extensions remain VM-only.
final class PatchbayDirectConnection implements PatchbayClient {
  static const String protocolPath = PatchbayDirectHost.protocolPathPrefix;

  PatchbayDirectConnection({
    required Uri endpoint,
    required String bearerToken,
    required int schemaVersion,
    required String applicationId,
    required String appInstanceId,
    Duration timeout = const Duration(seconds: 60),
  }) : _client = PatchbayDirectClient(
         session: PatchbayDirectSession.create(
           endpoint: endpoint,
           bearerToken: bearerToken,
           expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
           identity: PatchbayDirectIdentity(
             schemaVersion: schemaVersion,
             applicationId: applicationId,
             appInstanceId: appInstanceId,
           ),
           lanExposure: PatchbayLanExposure.experimentalSameTrustedNetworkOnly,
         ),
         timeout: timeout,
       );

  final PatchbayDirectClient _client;
  int _nextRequest = 0;

  @override
  Future<Map<String, Object?>> identity() => _translate(_client.identity);

  @override
  Future<Map<String, Object?>> catalog() => _translate(_client.catalog);

  @override
  Future<Map<String, Object?>> snapshot() => _translate(_client.snapshot);

  @override
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) => _translate(
    () => _client.invoke(
      command: command,
      arguments: arguments,
      requestId: requestId ?? 'patchbay-cli-direct-${++_nextRequest}',
      deadline: deadline,
    ),
  );

  @override
  Future<Map<String, Object?>> widgetTree() =>
      throw const PatchbayProtocolException('flutterDiagnosticUnavailable');

  @override
  Future<Map<String, Object?>> renderTree() =>
      throw const PatchbayProtocolException('flutterDiagnosticUnavailable');

  @override
  Future<Map<String, Object?>> focusTree() =>
      throw const PatchbayProtocolException('flutterDiagnosticUnavailable');

  @override
  Future<void> close() async => _client.close(force: true);

  static Future<Map<String, Object?>> _translate(
    Future<Map<String, Object?>> Function() operation,
  ) async {
    try {
      return await operation();
    } on PatchbayDirectClientException catch (error) {
      if (error.code == 'identityMismatch' ||
          error.code == 'protocolError' ||
          error.code == 'responseTooLarge') {
        throw PatchbayProtocolException(error.code);
      }
      throw PatchbayTransportException(error.code);
    }
  }
}
