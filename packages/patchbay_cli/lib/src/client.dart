import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

final class PatchbayProtocolException implements Exception {
  const PatchbayProtocolException(this.code);

  final String code;
}

final class PatchbayConnection {
  PatchbayConnection._(this._service, this.isolateId, this._extensionRPCs);

  final VmService _service;
  final String isolateId;
  final Set<String> _extensionRPCs;

  static const String _inspectorTreeExtension =
      'ext.flutter.inspector.getRootWidgetTree';
  static const String _inspectorDisposeGroupExtension =
      'ext.flutter.inspector.disposeGroup';
  static const String _widgetDumpExtension = 'ext.flutter.debugDumpApp';
  static const String _renderDumpExtension = 'ext.flutter.debugDumpRenderTree';
  static const String _focusDumpExtension = 'ext.flutter.debugDumpFocusTree';

  static Future<PatchbayConnection> connect(Uri serviceUri) async {
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
            final PatchbayConnection connection = PatchbayConnection._(
              service,
              id,
              Set<String>.of(detail.extensionRPCs ?? const <String>[]),
            );
            final Map<String, Object?> identity = await connection.identity();
            if (identity['schemaVersion'] !=
                    PatchbayServiceHost.schemaVersion ||
                identity['isolateId'] != id ||
                identity['appInstanceId'] is! String) {
              throw const PatchbayProtocolException('identityValidationFailed');
            }
            return connection;
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

  Future<Map<String, Object?>> identity() =>
      _call(PatchbayServiceHost.identityMethod);

  Future<Map<String, Object?>> catalog() =>
      _call(PatchbayServiceHost.catalogMethod);

  Future<Map<String, Object?>> snapshot() =>
      _call(PatchbayServiceHost.snapshotMethod);

  /// Reads Flutter's own diagnostic extensions without translating their
  /// SDK-specific schema into the stable Patchbay protocol.
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

  Future<Map<String, Object?>> renderTree() => _textDiagnostic(
    extension: _renderDumpExtension,
    format: 'flutterRenderDumpText',
  );

  Future<Map<String, Object?>> focusTree() => _textDiagnostic(
    extension: _focusDumpExtension,
    format: 'flutterFocusDumpText',
  );

  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
  }) => _call(
    PatchbayServiceHost.invokeMethod,
    arguments: <String, Object?>{
      'command': command,
      'args': jsonEncode(arguments),
      'requestId': ?requestId,
    },
  );

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
