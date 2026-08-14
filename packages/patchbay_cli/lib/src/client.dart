import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

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
  const PatchbayTransportException(this.code);

  final String code;
}

final class PatchbayRuntimeIdentity {
  const PatchbayRuntimeIdentity({
    required this.schemaVersion,
    required this.applicationId,
    required this.appInstanceId,
    required this.isolateId,
  });

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
    );
  }

  final int schemaVersion;
  final String applicationId;
  final String appInstanceId;
  final String isolateId;
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

final class PatchbayConnection implements PatchbayClient {
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
  int _nextRequest = 0;

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
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    // The VM Service connection has no per-request teardown to protect against,
    // so a declared wait budget changes nothing here.
    Duration? deadline,
  }) async {
    if (requestId != null && requestId.isEmpty) {
      throw const PatchbayProtocolException('requestIdValidationFailed');
    }
    final String id = requestId ?? 'patchbay-cli-vm-${++_nextRequest}';
    final Map<String, Object?> result = await _call(
      PatchbayServiceHost.invokeMethod,
      arguments: <String, Object?>{
        'command': command,
        'args': jsonEncode(arguments),
        'requestId': id,
      },
    );
    if (result['requestId'] != id) {
      throw const PatchbayProtocolException('requestIdMismatch');
    }
    return result;
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
