import 'dart:async';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_transport/patchbay_transport.dart';

import 'client.dart';
import 'request_id.dart';
import 'performance_profile.dart';
import 'rpc_timeout.dart';

/// Adapts the explicit direct HTTP transport to the same command client used
/// by the VM Service path. Flutter SDK diagnostic extensions remain VM-only.
final class PatchbayDirectConnection
    implements
        PatchbayClient,
        PatchbayProfilingClient,
        PatchbaySnapshotDiffClient,
        PatchbayCancelableInvocationClient {
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
  Set<String>? _features;
  bool _identityRead = false;
  final Map<(String, String), _DirectOwnerTokenLease> _ownerTokens =
      <(String, String), _DirectOwnerTokenLease>{};

  @override
  Future<Map<String, Object?>> identity() async {
    final Map<String, Object?> result = await _translate(_client.identity);
    final Object? declared = result['features'];
    if (declared is List<Object?> &&
        declared.every((Object? value) => value is String)) {
      _features = <String>{
        for (final Object? value in declared) value! as String,
      };
    } else {
      _features = null;
    }
    _identityRead = true;
    return result;
  }

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
  Future<Map<String, Object?>> snapshotDiff({required int fromRevision}) =>
      _translate(
        () => _client.snapshot(
          request: PatchbaySnapshotDiffRequest(
            fromRevision: fromRevision,
          ).toWire().toJson(),
        ),
      );

  @override
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) async => beginInvocation(
    command: command,
    arguments: arguments,
    requestId: requestId,
    deadline: deadline,
  ).response;

  @override
  PatchbayClientInvocationHandle beginInvocation({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) {
    final String id = requestId ?? patchbayCliRequestId('direct');
    var cooperativeKnown = false;
    final Completer<_DirectOwnerTokenLease?> ownerReady =
        Completer<_DirectOwnerTokenLease?>();
    final Future<Map<String, Object?>> response = () async {
      _DirectOwnerTokenLease? lease;
      try {
        if (requestId != null && requestId.isEmpty) {
          throw const PatchbayProtocolException('requestIdValidationFailed');
        }
        if (!_identityRead) await identity();
        final bool cooperative =
            _features?.contains(PatchbayFeature.invocationCancellation.name) ??
            false;
        lease = cooperative ? _acquireOwnerToken(command, id) : null;
        cooperativeKnown = lease != null;
        ownerReady.complete(lease);
        var succeeded = false;
        late final Map<String, Object?> result;
        try {
          result = await _translate(
            () => _client.invoke(
              command: command,
              arguments: arguments,
              requestId: id,
              deadline: deadline,
              ownerToken: lease?.token,
            ),
          );
          succeeded = true;
        } finally {
          if (lease != null) {
            _releaseOwnerToken(command, id, lease, succeeded);
          }
        }
        if (result['requestId'] != id) {
          throw const PatchbayProtocolException('requestIdMismatch');
        }
        return result;
      } finally {
        if (!ownerReady.isCompleted) ownerReady.complete(null);
      }
    }();
    return PatchbayClientInvocationHandle(
      response: response,
      cancellationSupported: () => cooperativeKnown,
      requestCancellation: () async {
        final _DirectOwnerTokenLease? lease = await ownerReady.future;
        if (lease == null) {
          throw const PatchbayTransportException(
            patchbayAppUnresponsiveCode,
            details: <String, Object?>{'cancellationMode': 'legacyWaitOnly'},
          );
        }
        return _translate(
          () => _client.cancelInvocation(
            command: command,
            requestId: id,
            ownerToken: lease.token,
          ),
        );
      },
    );
  }

  _DirectOwnerTokenLease _acquireOwnerToken(String command, String requestId) {
    final (String, String) key = (command, requestId);
    final _DirectOwnerTokenLease? existing = _ownerTokens[key];
    if (existing != null) {
      existing.users += 1;
      return existing;
    }
    if (_ownerTokens.length >= 256) {
      (String, String)? evicted;
      for (final MapEntry<(String, String), _DirectOwnerTokenLease> entry
          in _ownerTokens.entries) {
        if (entry.value.users != 0) continue;
        evicted = entry.key;
        break;
      }
      if (evicted != null) _ownerTokens.remove(evicted);
    }
    final _DirectOwnerTokenLease created = _DirectOwnerTokenLease(
      patchbayGenerateOwnerToken(),
    );
    _ownerTokens[key] = created;
    return created;
  }

  void _releaseOwnerToken(
    String command,
    String requestId,
    _DirectOwnerTokenLease lease,
    bool succeeded,
  ) {
    lease.users -= 1;
    if (succeeded && lease.users == 0) {
      _ownerTokens.remove((command, requestId));
    }
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

final class _DirectOwnerTokenLease {
  _DirectOwnerTokenLease(this.token);

  final String token;
  int users = 1;
}
