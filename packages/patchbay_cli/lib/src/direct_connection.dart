import 'package:patchbay/patchbay.dart';
import 'package:patchbay_transport/patchbay_transport.dart';

import 'client.dart';
import 'request_id.dart';
import 'performance_profile.dart';
import 'rpc_timeout.dart';

/// Adapts the explicit direct HTTP transport to the same command client used
/// by the VM Service path. Flutter SDK diagnostic extensions remain VM-only.
final class PatchbayDirectConnection
    implements PatchbayClient, PatchbayProfilingClient {
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

  @override
  Future<Map<String, Object?>> identity() => _translate(_client.identity);

  @override
  Future<Map<String, Object?>> catalog() => _translate(_client.catalog);

  @override
  Future<Map<String, Object?>> snapshot({PatchbaySnapshotRequest? request}) =>
      _translate(
        () => _client.snapshot(
          request: request?.toWire().toJson(),
          deadline: request?.timeout,
        ),
      );

  @override
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) async {
    if (requestId != null && requestId.isEmpty) {
      throw const PatchbayProtocolException('requestIdValidationFailed');
    }
    final String id = requestId ?? patchbayCliRequestId('direct');
    final Map<String, Object?> result = await _translate(
      () => _client.invoke(
        command: command,
        arguments: arguments,
        requestId: id,
        deadline: deadline,
      ),
    );
    if (result['requestId'] != id) {
      throw const PatchbayProtocolException('requestIdMismatch');
    }
    return result;
  }

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
  Future<Map<String, Object?>> performanceProfile(
    PatchbayPerformanceProfileRequest request,
  ) async => throw const PatchbayProtocolException(
    'profilingVmServiceRequired',
    details: <String, Object?>{'capability': 'performanceProfile'},
  );

  @override
  Future<Map<String, Object?>> networkProfile() async =>
      throw const PatchbayProtocolException(
        'networkProfilingUnavailable',
        details: <String, Object?>{'reason': 'privacySafeCollectorUnavailable'},
      );

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
          error.code == 'requestIdMismatch' ||
          error.code == 'responseTooLarge') {
        throw PatchbayProtocolException(error.code);
      }
      // The transport package names its own socket budget `timeout`; the CLI
      // says the same thing about the peer rather than about the socket, and
      // says it identically on both transports so one code classifies an
      // unresponsive App however the CLI reached it.
      if (error.code == 'timeout') {
        throw const PatchbayTransportException(patchbayAppUnresponsiveCode);
      }
      throw PatchbayTransportException(error.code);
    }
  }
}
