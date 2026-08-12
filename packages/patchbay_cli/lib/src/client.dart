import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

final class PatchbayProtocolException implements Exception {
  const PatchbayProtocolException(this.code);

  final String code;
}

final class PatchbayConnection {
  PatchbayConnection._(this._service, this.isolateId);

  final VmService _service;
  final String isolateId;

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
