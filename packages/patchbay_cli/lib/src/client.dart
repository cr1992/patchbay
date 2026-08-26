import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'request_id.dart';
import 'performance_profile.dart';

final class PatchbayProtocolException implements Exception {
  const PatchbayProtocolException(
    this.code, {
    this.details = const <String, Object?>{},
  });

  final String code;

  /// What the host already told the CLI about this failure.
  ///
  /// The code names the class; this carries whatever the App said that the code
  /// cannot express — the catalog violation behind a drift, for instance. It is
  /// host data passed through unchanged, so it never gains a CLI-side meaning.
  final Map<String, Object?> details;
}

final class PatchbayTransportException implements Exception {
  const PatchbayTransportException(
    this.code, {
    this.details = const <String, Object?>{},
  });

  final String code;
  final Map<String, Object?> details;
}

final class PatchbayRuntimeIdentity {
  const PatchbayRuntimeIdentity({
    required this.schemaVersion,
    required this.applicationId,
    required this.appInstanceId,
    required this.isolateId,
    this.serverVersion,
    this.features,
  });

  /// Reads one identity answer.
  ///
  /// [serverVersion] and [features] are read *leniently* while the four
  /// original fields stay strict, and the difference is deliberate: a host
  /// that predates them is a supported peer, not a broken one, so their
  /// absence has to survive validation and reach the caller as "not reported".
  /// A present-but-wrong-typed value is the opposite — nothing in the wire
  /// contract can produce it, so it is a host bug and fails closed like any
  /// other malformed identity.
  factory PatchbayRuntimeIdentity.fromJson(Map<String, Object?> json) {
    final schemaVersion = json['schemaVersion'];
    final applicationId = json['applicationId'];
    final appInstanceId = json['appInstanceId'];
    final isolateId = json['isolateId'];
    if (schemaVersion is! int ||
        applicationId is! String ||
        applicationId.isEmpty ||
        appInstanceId is! String ||
        appInstanceId.isEmpty ||
        isolateId is! String ||
        isolateId.isEmpty) {
      throw const PatchbayProtocolException('identityValidationFailed');
    }
    return PatchbayRuntimeIdentity(
      schemaVersion: schemaVersion,
      applicationId: applicationId,
      appInstanceId: appInstanceId,
      isolateId: isolateId,
      serverVersion: patchbayReportedServerVersion(json),
      features: patchbayDeclaredFeatures(json),
    );
  }

  final int schemaVersion;
  final String applicationId;
  final String appInstanceId;
  final String isolateId;

  /// The `patchbay` package version the host was built from, or null when the
  /// host does not report one.
  final String? serverVersion;

  /// The capabilities the host declares, or null when it declares nothing at
  /// all.
  ///
  /// Null and empty are different answers and must stay different: an empty
  /// set is a host saying "I have none of them", null is a host that predates
  /// the declaration and about which nothing may be concluded.
  final Set<String>? features;
}

/// Reads `serverVersion` out of an identity answer.
///
/// Returns null when the host does not report one. Throws only for a value
/// that is present and not a string, because no version of this protocol can
/// produce that.
String? patchbayReportedServerVersion(Map<String, Object?> identity) {
  final Object? value = identity['serverVersion'];
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw const PatchbayProtocolException('identityValidationFailed');
  }
  return value;
}

/// Reads the declared capability set out of an identity answer.
///
/// Unknown names are kept rather than dropped: a client that meets a newer
/// host must be able to say *which* capability it does not use, and the whole
/// reason capabilities are read as strings is that a newer name is normal
/// traffic, not a decode failure.
Set<String>? patchbayDeclaredFeatures(Map<String, Object?> identity) {
  final Object? value = identity['features'];
  if (value == null) return null;
  if (value is! List<Object?> || value.any((Object? name) => name is! String)) {
    throw const PatchbayProtocolException('identityValidationFailed');
  }
  return <String>{for (final Object? name in value) name! as String};
}

abstract interface class PatchbayClient {
  Future<Map<String, Object?>> identity();
  Future<Map<String, Object?>> catalog();

  /// [request] selects one field and may ask the App to wait for a condition
  /// on it. Passing none reads the whole snapshot, as it always did.
  Future<Map<String, Object?>> snapshot({PatchbaySnapshotRequest? request});

  /// [deadline] is how long the caller intends to wait for a long-poll command.
  /// Transports that cannot be torn down by one slow request may ignore it.
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  });
  Future<Map<String, Object?>> widgetTree();
  Future<Map<String, Object?>> renderTree();
  Future<Map<String, Object?>> focusTree();
  Future<void> close();
}

/// Optional client surface for the separately capability-gated diff request.
///
/// Kept out of [PatchbayClient] so adding PB-040-10 does not break third-party
/// test or transport adapters that implemented the published 0.3 interface.
abstract interface class PatchbaySnapshotDiffClient {
  Future<Map<String, Object?>> snapshotDiff({required int fromRevision});
}

/// One invocation plus its optional protocol-owned cancellation operation.
final class PatchbayClientInvocationHandle {
  PatchbayClientInvocationHandle({
    required this.response,
    this.requestCancellation,
    bool Function()? cancellationSupported,
  }) : _cancellationSupported =
           cancellationSupported ?? (() => requestCancellation != null);

  final Future<Map<String, Object?>> response;
  final Future<Map<String, Object?>> Function()? requestCancellation;
  final bool Function() _cancellationSupported;

  bool get cancellationSupported => _cancellationSupported();
}

/// Optional surface used by the timeout wrapper when a feature-aware host
/// stops answering before an invocation returned a terminal envelope.
abstract interface class PatchbayCancelableInvocationClient {
  PatchbayClientInvocationHandle beginInvocation({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  });
}

final class PatchbayConnection
    implements
        PatchbayClient,
        PatchbayProfilingClient,
        PatchbaySnapshotDiffClient,
        PatchbayCancelableInvocationClient {
  PatchbayConnection._(
    this._service,
    this.isolateId,
    this._extensionRPCs,
    this.runtimeIdentity,
  );

  final VmService _service;
  final String isolateId;
  final Set<String> _extensionRPCs;
  final PatchbayRuntimeIdentity runtimeIdentity;
  final Map<(String, String), _InvocationOwnerTokenLease> _ownerTokens =
      <(String, String), _InvocationOwnerTokenLease>{};

  static const String _inspectorTreeExtension =
      'ext.flutter.inspector.getRootWidgetTree';
  static const String _inspectorDisposeGroupExtension =
      'ext.flutter.inspector.disposeGroup';
  static const String _widgetDumpExtension = 'ext.flutter.debugDumpApp';
  static const String _renderDumpExtension = 'ext.flutter.debugDumpRenderTree';
  static const String _focusDumpExtension = 'ext.flutter.debugDumpFocusTree';

  static Future<PatchbayConnection> connect(
    Uri serviceUri, {
    PatchbayRuntimeIdentity? expectedIdentity,
  }) async {
    final VmService service = await vmServiceConnectUri(
      _webSocketUri(serviceUri).toString(),
    );
    try {
      for (var attempt = 0; attempt < 50; attempt += 1) {
        final VM vm = await service.getVM();
        for (final IsolateRef isolate in vm.isolates ?? const <IsolateRef>[]) {
          final String? id = isolate.id;
          if (id == null) continue;
          final Isolate detail = await service.getIsolate(id);
          if (detail.extensionRPCs?.contains(
                PatchbayServiceHost.identityMethod,
              ) ??
              false) {
            final Map<String, Object?> identityJson = await _callIdentity(
              service,
              id,
            );
            final PatchbayRuntimeIdentity identity =
                PatchbayRuntimeIdentity.fromJson(identityJson);
            if (identity.schemaVersion != PatchbayServiceHost.schemaVersion ||
                identity.isolateId != id ||
                (expectedIdentity != null &&
                    (identity.schemaVersion != expectedIdentity.schemaVersion ||
                        identity.applicationId !=
                            expectedIdentity.applicationId ||
                        identity.appInstanceId !=
                            expectedIdentity.appInstanceId ||
                        identity.isolateId != expectedIdentity.isolateId))) {
              throw const PatchbayProtocolException('identityValidationFailed');
            }
            return PatchbayConnection._(
              service,
              id,
              Set<String>.of(detail.extensionRPCs ?? const <String>[]),
              identity,
            );
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw StateError('VM has no isolate with Patchbay extensions');
    } catch (_) {
      await service.dispose();
      rethrow;
    }
  }

  static Future<Map<String, Object?>> _callIdentity(
    VmService service,
    String isolateId,
  ) async {
    final Response response = await service.callServiceExtension(
      PatchbayServiceHost.identityMethod,
      isolateId: isolateId,
    );
    final json = response.json;
    if (json == null) {
      throw const PatchbayProtocolException('identityValidationFailed');
    }
    return Map<String, Object?>.from(json);
  }

  @override
  Future<Map<String, Object?>> identity() =>
      _call(PatchbayServiceHost.identityMethod);

  @override
  Future<Map<String, Object?>> catalog() =>
      _call(PatchbayServiceHost.catalogMethod);

  @override
  Future<Map<String, Object?>> snapshot({PatchbaySnapshotRequest? request}) =>
      _call(
        PatchbayServiceHost.snapshotMethod,
        arguments: request == null
            ? null
            : <String, Object?>{
                PatchbayServiceHost.snapshotRequestKey: jsonEncode(
                  request.toWire().toJson(),
                ),
              },
      );

  @override
  Future<Map<String, Object?>> snapshotDiff({required int fromRevision}) =>
      _call(
        PatchbayServiceHost.snapshotMethod,
        arguments: <String, Object?>{
          PatchbayServiceHost.snapshotRequestKey: jsonEncode(
            PatchbaySnapshotDiffRequest(
              fromRevision: fromRevision,
            ).toWire().toJson(),
          ),
        },
      );

  /// Reads Flutter's own diagnostic extensions without translating their
  /// SDK-specific schema into the stable Patchbay protocol.
  @override
  Future<Map<String, Object?>> widgetTree() async {
    if (await _supportsExtension(_inspectorTreeExtension)) {
      final String group =
          'patchbay-cli-${DateTime.now().microsecondsSinceEpoch}';
      try {
        final Map<String, Object?> response = await _callRaw(
          _inspectorTreeExtension,
          arguments: <String, Object?>{
            'groupName': group,
            'isSummaryTree': 'true',
            'withPreviews': 'true',
            'fullDetails': 'true',
          },
        );
        return _diagnosticEnvelope(
          extension: _inspectorTreeExtension,
          format: 'flutterInspectorJson',
          data: response['result'],
        );
      } finally {
        if (await _supportsExtension(_inspectorDisposeGroupExtension)) {
          await _callRaw(
            _inspectorDisposeGroupExtension,
            arguments: <String, Object?>{'objectGroup': group},
          );
        }
      }
    }
    return _textDiagnostic(
      extension: _widgetDumpExtension,
      format: 'flutterWidgetDumpText',
    );
  }

  @override
  Future<Map<String, Object?>> renderTree() => _textDiagnostic(
    extension: _renderDumpExtension,
    format: 'flutterRenderDumpText',
  );

  @override
  Future<Map<String, Object?>> focusTree() => _textDiagnostic(
    extension: _focusDumpExtension,
    format: 'flutterFocusDumpText',
  );

  @override
  Future<Map<String, Object?>> performanceProfile(
    PatchbayPerformanceProfileRequest request,
  ) => PatchbayVmPerformanceProfiler(
    source: PatchbayVmServicePerformanceSource(_service),
  ).collect(isolateId: isolateId, request: request);

  /// The public `vm_service` HTTP profiler returns bodies, headers, cookies and
  /// query values before a caller can filter them. Collecting that response and
  /// redacting afterwards would cross the accepted privacy boundary, so this
  /// transport publishes no network capability and refuses with one stable
  /// code instead of touching the RPC.
  @override
  Future<Map<String, Object?>> networkProfile() async =>
      throw const PatchbayProtocolException(
        'networkProfilingUnavailable',
        details: <String, Object?>{
          'reason': 'privacySafeVmRpcUnavailable',
          'reviewedVmServicePackage': '15.2.0',
        },
      );

  @override
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    // The VM Service connection has no per-request teardown to protect against,
    // so a declared wait budget changes nothing here.
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
    if (requestId != null && requestId.isEmpty) {
      throw const PatchbayProtocolException('requestIdValidationFailed');
    }
    final String id = requestId ?? patchbayCliRequestId('vm');
    final bool cooperative =
        runtimeIdentity.features?.contains(
          PatchbayFeature.invocationCancellation.name,
        ) ??
        false;
    final _InvocationOwnerTokenLease? lease = cooperative
        ? _acquireOwnerToken(command, id)
        : null;
    final Future<Map<String, Object?>> response = () async {
      var succeeded = false;
      late final Map<String, Object?> result;
      try {
        result = await _call(
          PatchbayServiceHost.invokeMethod,
          arguments: <String, Object?>{
            'command': command,
            'args': jsonEncode(arguments),
            'requestId': id,
            if (cooperative && deadline != null)
              'deadlineMs': deadline.inMilliseconds,
            if (lease != null) 'ownerToken': lease.token,
          },
        );
        succeeded = true;
      } finally {
        if (lease != null) _releaseOwnerToken(command, id, lease, succeeded);
      }
      if (result['requestId'] != id) {
        throw const PatchbayProtocolException('requestIdMismatch');
      }
      return result;
    }();
    return PatchbayClientInvocationHandle(
      response: response,
      requestCancellation: lease == null
          ? null
          : () => _call(
              PatchbayServiceHost.cancelInvocationMethod,
              arguments: <String, Object?>{
                'command': command,
                'requestId': id,
                'ownerToken': lease.token,
              },
            ),
    );
  }

  _InvocationOwnerTokenLease _acquireOwnerToken(
    String command,
    String requestId,
  ) {
    final (String, String) key = (command, requestId);
    final _InvocationOwnerTokenLease? existing = _ownerTokens[key];
    if (existing != null) {
      existing.users += 1;
      return existing;
    }
    if (_ownerTokens.length >= 256) {
      (String, String)? evicted;
      for (final MapEntry<(String, String), _InvocationOwnerTokenLease> entry
          in _ownerTokens.entries) {
        if (entry.value.users != 0) continue;
        evicted = entry.key;
        break;
      }
      if (evicted != null) _ownerTokens.remove(evicted);
    }
    final _InvocationOwnerTokenLease created = _InvocationOwnerTokenLease(
      patchbayGenerateOwnerToken(),
    );
    _ownerTokens[key] = created;
    return created;
  }

  void _releaseOwnerToken(
    String command,
    String requestId,
    _InvocationOwnerTokenLease lease,
    bool succeeded,
  ) {
    lease.users -= 1;
    if (succeeded && lease.users == 0) {
      _ownerTokens.remove((command, requestId));
    }
  }

  Future<Map<String, Object?>> _call(
    String method, {
    Map<String, Object?>? arguments,
  }) async {
    final Response response = await _service.callServiceExtension(
      method,
      isolateId: isolateId,
      args: arguments,
    );
    final Map<String, dynamic>? json = response.json;
    if (json == null) throw StateError('$method returned no JSON object');
    if (json['schemaVersion'] != PatchbayServiceHost.schemaVersion) {
      throw const PatchbayProtocolException('schemaVersionMismatch');
    }
    return Map<String, Object?>.from(json);
  }

  Future<Map<String, Object?>> _textDiagnostic({
    required String extension,
    required String format,
  }) async {
    if (!await _supportsExtension(extension)) {
      throw const PatchbayProtocolException('flutterDiagnosticUnavailable');
    }
    final Map<String, Object?> response = await _callRaw(extension);
    return _diagnosticEnvelope(
      extension: extension,
      format: format,
      data: response['data'],
    );
  }

  Future<bool> _supportsExtension(String method) async {
    if (_extensionRPCs.contains(method)) return true;
    final Isolate isolate = await _service.getIsolate(isolateId);
    _extensionRPCs
      ..clear()
      ..addAll(isolate.extensionRPCs ?? const <String>[]);
    return _extensionRPCs.contains(method);
  }

  Future<Map<String, Object?>> _callRaw(
    String method, {
    Map<String, Object?>? arguments,
  }) async {
    final Response response = await _service.callServiceExtension(
      method,
      isolateId: isolateId,
      args: arguments,
    );
    final Map<String, dynamic>? json = response.json;
    if (json == null) throw StateError('$method returned no JSON object');
    return Map<String, Object?>.from(json);
  }

  static Map<String, Object?> _diagnosticEnvelope({
    required String extension,
    required String format,
    required Object? data,
  }) => <String, Object?>{
    'source': PatchbayFactSource.uiObserved.name,
    'plane': 'flutterDiagnostic',
    'schema': 'flutterSdkPassthrough',
    'extension': extension,
    'format': format,
    'data': data,
    'warnings': const <String>[
      'Flutter diagnostic fields may change with the Flutter SDK.',
    ],
  };

  @override
  Future<void> close() => _service.dispose();

  static Uri _webSocketUri(Uri uri) {
    if (uri.scheme == 'ws' || uri.scheme == 'wss') return uri;
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw FormatException('VM Service URI must use http(s) or ws(s)');
    }
    final String path = uri.path.endsWith('/')
        ? '${uri.path}ws'
        : '${uri.path}/ws';
    return uri.replace(
      scheme: uri.scheme == 'https' ? 'wss' : 'ws',
      path: path,
    );
  }
}

final class _InvocationOwnerTokenLease {
  _InvocationOwnerTokenLease(this.token);

  final String token;
  int users = 1;
}
